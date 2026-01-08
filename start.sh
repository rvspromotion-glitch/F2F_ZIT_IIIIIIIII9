#!/usr/bin/env bash
set -euo pipefail

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"

# Persistent RunPod volume (set RUNPOD_VOLUME in template if you want)
PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-slim}"

# Optional baked fallback (if /workspace is a mounted empty volume)
BAKED_DIR="${COMFYUI_BAKED:-/opt/ComfyUI}"

mkdir -p "$(dirname "$COMFY_DIR")" "$PERSIST_DIR"

# If ComfyUI is missing but baked exists, restore it (RunPod mount scenario)
if [ ! -f "${COMFY_DIR}/main.py" ] && [ -f "${BAKED_DIR}/main.py" ]; then
  echo "[setup] Restoring ComfyUI from ${BAKED_DIR} -> ${COMFY_DIR} (mount detected)"
  rm -rf "${COMFY_DIR}"
  cp -a "${BAKED_DIR}" "${COMFY_DIR}"
fi

if [ ! -f "${COMFY_DIR}/main.py" ]; then
  echo "[fatal] ComfyUI not found at ${COMFY_DIR}. Check Dockerfile build or volume mount."
  exit 1
fi

mkdir -p "${CUSTOM_NODES}" "${MODELS_DIR}"

# -----------------------------
# Make git non-interactive and avoid inherited credential helpers/headers
# -----------------------------
git config --global --unset-all http.https://github.com/.extraheader 2>/dev/null || true
git config --global --unset-all credential.helper 2>/dev/null || true

# -----------------------------
# Speed: persistent pip cache
# -----------------------------
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$PIP_CACHE_DIR"

# -----------------------------
# Hard constraints (prevents numpy2 / transformers drift)
# Also pin opencv to avoid numpy>=2 requirement from opencv 4.12+
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
protobuf<5
transformers==4.39.3
tokenizers==0.15.2
safetensors
mediapipe==0.10.14
opencv-python<4.12
sageattention
EOF

export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

pip install -q --upgrade --prefer-binary \
  -c "$CONSTRAINTS_FILE" \
  "numpy<2" \
  "protobuf<5" \
  "transformers==4.39.3" \
  "tokenizers==0.15.2" \
  "safetensors" \
  "mediapipe==0.10.14" \
  "opencv-python<4.12" \
  "sageattention" || true

echo "[debug] Versions:"
python3 - <<'PY'
import sys
print("python:", sys.version)
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy
print("numpy:", numpy.__version__)
import transformers
print("transformers:", transformers.__version__)
import mediapipe
print("mediapipe:", getattr(mediapipe, "__version__", "unknown"), "solutions:", hasattr(mediapipe, "solutions"))
try:
    import cv2
    print("opencv:", cv2.__version__)
except Exception as e:
    print("opencv: not available:", e)
PY

# -----------------------------
# Helpers
# -----------------------------
download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"

  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[models] exists: $out"
    return 0
  fi

  echo "[models] downloading: $out"

  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x 16 -s 16 -k 1M \
      --allow-overwrite=true \
      --file-allocation=none \
      -d "$(dirname "$out")" -o "$(basename "$out")" \
      "$url"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 8 --retry-delay 2 -C - -o "$out" "$url"
  else
    wget -c -O "$out" "$url"
  fi
}

civit_download() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"

  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[civitai] exists: $out"
    return 0
  fi

  echo "[civitai] downloading: $out"

  local header=()
  if [ -n "${CIVITAI_TOKEN:-}" ]; then
    header+=( -H "Authorization: Bearer ${CIVITAI_TOKEN}" )
  fi

  curl -L --fail --retry 10 --retry-delay 2 -C - \
    "${header[@]}" \
    -o "$out" "$url"

  if file "$out" | grep -qi "HTML"; then
    echo "[civitai] ERROR: got HTML instead of model (token missing/invalid/gated). Removing $out"
    rm -f "$out"
    return 1
  fi
}

env_lora_download() {
  local url_var="$1"
  local filename="${2:-}"
  local out_dir="${MODELS_DIR}/loras"

  local url="${!url_var:-}"
  if [ -z "$url" ]; then
    echo "[lora] env ${url_var} is empty -> skip"
    return 0
  fi

  mkdir -p "$out_dir"

  if [ -z "$filename" ]; then
    filename="$(basename "${url%%\?*}")"
  fi

  filename="${filename// /_}"
  local out="${out_dir}/${filename}"

  echo "[lora] url_var=${url_var}"
  echo "[lora] url=${url}"
  echo "[lora] out=${out}"

  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[lora] exists: $out"
    return 0
  fi

  curl -L --fail --retry 10 --retry-delay 2 -C - \
    -A "Mozilla/5.0" \
    -o "$out" "$url"

  if file "$out" | grep -qi "HTML"; then
    echo "[lora] ERROR: got HTML instead of model (Dropbox auth/blocked). Removing $out"
    rm -f "$out"
    return 1
  fi

  echo "[lora] done: $(ls -lh "$out" | awk '{print $5, $9}')"
}

# Install node requirements but never allow torch stack / numpy / transformers / opencv to be changed.
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf|opencv-python)([<=> ].*)?$' "$req" > "$tmpreq" || true

  pip install -q --prefer-binary -c "$CONSTRAINTS_FILE" -r "$tmpreq" || true
  rm -f "$tmpreq"
}

# -----------------------------
# Model directories
# -----------------------------
mkdir -p \
  "${MODELS_DIR}/sams" \
  "${MODELS_DIR}/ultralytics/bbox" \
  "${MODELS_DIR}/ultralytics/segm" \
  "${MODELS_DIR}/diffusion_models" \
  "${MODELS_DIR}/vae" \
  "${MODELS_DIR}/clip" \
  "${MODELS_DIR}/loras" \
  "${MODELS_DIR}/checkpoints"

chmod -R 777 "${MODELS_DIR}/loras" || true

# -----------------------------
# Model downloads (parallel batches)
# -----------------------------
echo "[models] Downloading required models (parallel batches)..."

download "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_b_01ec64.pth" \
  "${MODELS_DIR}/sams/sam_vit_b_01ec64.pth" &
download "https://dl.fbaipublicfiles.com/segment_anything/sam_vit_l_0b3195.pth" \
  "${MODELS_DIR}/sams/sam_vit_l_0b3195.pth" &

download "https://huggingface.co/datasets/Gourieff/ReActor/resolve/main/models/detection/bbox/face_yolov8m.pt" \
  "${MODELS_DIR}/ultralytics/bbox/face_yolov8m.pt" &
download "https://huggingface.co/Bingsu/adetailer/resolve/main/person_yolov8m-seg.pt" \
  "${MODELS_DIR}/ultralytics/segm/person_yolov8m-seg.pt" &
wait

download "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n.pt" \
  "${MODELS_DIR}/ultralytics/bbox/yolov8n.pt" &
download "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n-pose.pt" \
  "${MODELS_DIR}/ultralytics/bbox/yolov8n-pose.pt" &
download "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8m.pt" \
  "${MODELS_DIR}/ultralytics/bbox/yolov8m.pt" &
download "https://huggingface.co/Bingsu/adetailer/resolve/main/hand_yolov8n.pt" \
  "${MODELS_DIR}/ultralytics/bbox/hand_yolov8n.pt" &

download "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8n-seg.pt" \
  "${MODELS_DIR}/ultralytics/segm/yolov8n-seg.pt" &
download "https://github.com/ultralytics/assets/releases/download/v8.3.0/yolov8m-seg.pt" \
  "${MODELS_DIR}/ultralytics/segm/yolov8m-seg.pt" &
wait

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
  "${MODELS_DIR}/diffusion_models/z_image_turbo_bf16.safetensors" &
download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
  "${MODELS_DIR}/vae/ae.safetensors" &
download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" \
  "${MODELS_DIR}/clip/qwen_3_4b.safetensors" &
wait

# -----------------------------
# Optional character LoRA via env var
# -----------------------------
env_lora_download "CHAR_LORA_URL" &
wait

echo "[models] Downloads completed."

# =============================
# Custom Nodes: clone + install (cached, non-fatal)
# =============================
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE" "$CUSTOM_NODES"

UPDATE_NODES="${UPDATE_NODES:-0}"
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"

# during debugging, set FORCE_NODE_REQS=1 to ignore the marker
FORCE_NODE_REQS="${FORCE_NODE_REQS:-0}"
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"

# Always use pip tied to python3
PIP="python3 -m pip"

clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${REPO_CACHE}/${name}"

  if [ ! -d "${dest}/.git" ]; then
    echo "[nodes] cloning ${name}..."
    rm -rf "$dest"
    if ! GIT_TERMINAL_PROMPT=0 git clone --depth 1 --progress "$url" "$dest"; then
      echo "[nodes] WARNING: failed to clone ${name}, skipping"
      rm -rf "$dest"
      return 0
    fi
  elif [ "$UPDATE_NODES" = "1" ]; then
    echo "[nodes] updating ${name}..."
    git -C "$dest" pull --rebase || true
  else
    echo "[nodes] cached ${name} (no pull)"
  fi

  # Find actual node root:
  # Prefer a folder that contains __init__.py (ComfyUI custom node convention)
  local node_root="$dest"
  if [ ! -f "${node_root}/__init__.py" ]; then
    # common pattern: repo/custom_nodes/<NodeName> or repo/<NodeName>
    local candidate
    candidate="$(find "$dest" -maxdepth 3 -type f -name "__init__.py" \
      ! -path "*/.git/*" ! -path "*/__pycache__/*" | head -n 1 || true)"
    if [ -n "$candidate" ]; then
      node_root="$(dirname "$candidate")"
    fi
  fi

  echo "[nodes] link: ${name} -> ${node_root}"
  ln -sfn "$node_root" "${CUSTOM_NODES}/${name}"
}

echo "==================================="
echo "Installing custom nodes (cached)"
echo "==================================="

# These provide your missing nodes:
clone_or_update "ComfyUI-KJNodes"            "https://github.com/kijai/ComfyUI-KJNodes.git"          # Film Grain, SequentialNumberGenerator, MotionBlending
clone_or_update "ComfyUI-VFI"                "https://github.com/Fannovel16/ComfyUI-VFI.git"        # RIFE VFI
clone_or_update "ComfyUI-WanVideoWrapper"    "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" # WanVideoImageResizeToClosest
clone_or_update "ComfyUI-Custom-Scripts"     "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git" # TextBox1

# Your other packs:
clone_or_update "ComfyUI-Impact-Pack"        "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
clone_or_update "ComfyUI-Impact-Subpack"     "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
clone_or_update "ComfyUI-VideoHelperSuite"   "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_update "ComfyUI-GGUF"               "https://github.com/city96/ComfyUI-GGUF.git"
clone_or_update "ComfyUI_essentials"         "https://github.com/cubiq/ComfyUI_essentials.git"
clone_or_update "a-person-mask-generator"    "https://github.com/djbielejeski/a-person-mask-generator.git"
clone_or_update "comfyui_controlnet_aux"     "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
clone_or_update "rgthree-comfy"              "https://github.com/rgthree/rgthree-comfy.git"

# Install requirements (once, constrained)
if [ "$INSTALL_NODE_REQS" = "1" ]; then
  if [ "$FORCE_NODE_REQS" = "1" ] || [ ! -f "$REQ_MARK" ] || [ "$UPDATE_NODES" = "1" ]; then
    echo "[pip] Installing node requirements (constrained)..."
    for dir in "${REPO_CACHE}"/*; do
      [ -d "$dir" ] || continue
      req="${dir}/requirements.txt"
      if [ -f "$req" ]; then
        echo "  - [pip] $(basename "$dir")/requirements.txt"
        safe_pip_install_req "$req"
      fi
    done
    touch "$REQ_MARK"
  else
    echo "[pip] Node requirements already installed (skip)"
  fi
fi

echo "[nodes] Listing custom_nodes:"
ls -la "$CUSTOM_NODES" || true

echo "[nodes] Done."

# Final safety
pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" "mediapipe==0.10.14" "opencv-python<4.12" || true

# -----------------------------
# Start JupyterLab
# -----------------------------
echo "[jupyter] Starting JupyterLab..."
jupyter lab \
  --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
  --ServerApp.token='' --ServerApp.password='' \
  --ServerApp.allow_origin='*' \
  --ServerApp.root_dir="${COMFY_DIR}" \
  >/workspace/jupyter.log 2>&1 &

echo "==================================="
echo "Launching ComfyUI"
echo "==================================="

cd "${COMFY_DIR}"
exec python3 main.py --listen 0.0.0.0 --port 8188
