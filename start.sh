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
# Speed: persistent pip cache
# -----------------------------
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$PIP_CACHE_DIR"

# -----------------------------
# Hard constraints (prevents numpy2 / transformers drift)
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
protobuf<5
transformers==4.39.3
tokenizers==0.15.2
safetensors
mediapipe==0.10.14
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

  # If we got HTML (login page), delete it so you dont think its a model
  if file "$out" | grep -qi "HTML"; then
    echo "[civitai] ERROR: got HTML instead of model (token missing/invalid/gated). Removing $out"
    rm -f "$out"
    return 1
  fi
}

env_lora_download() {
  local url_var="$1"      # env var name, e.g. CHAR_LORA_URL
  local filename="${2:-}" # optional output filename override
  local out_dir="${MODELS_DIR}/loras"

  local url="${!url_var:-}"
  if [ -z "$url" ]; then
    echo "[lora] env ${url_var} is empty -> skip"
    return 0
  fi

  mkdir -p "$out_dir"

  # Auto-name from URL if not provided
  if [ -z "$filename" ]; then
    filename="$(basename "${url%%\?*}")"
  fi

  # sanitize spaces just in case
  filename="${filename// /_}"

  local out="${out_dir}/${filename}"

  echo "[lora] url_var=${url_var}"
  echo "[lora] url=${url}"
  echo "[lora] out=${out}"

  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[lora] exists: $out"
    return 0
  fi

  # Dropbox can be picky; use curl with UA + retries + resume
  curl -L --fail --retry 10 --retry-delay 2 -C - \
    -A "Mozilla/5.0" \
    -o "$out" "$url"

  # Detect HTML instead of a safetensors binary
  if file "$out" | grep -qi "HTML"; then
    echo "[lora] ERROR: got HTML instead of model (Dropbox auth/blocked). Removing $out"
    rm -f "$out"
    return 1
  fi

  echo "[lora] done: $(ls -lh "$out" | awk '{print $5, $9}')"
}

# Install node requirements but never allow torch stack / numpy / transformers to be changed.
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  # Filter lines that must never override global pins
  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf)([<=> ].*)?$' "$req" > "$tmpreq" || true

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

civit_download "https://civitai.com/api/download/models/1511445?type=Model&format=SafeTensor" \
  "${MODELS_DIR}/loras/1511445_Spread i5XL.safetensors" &
civit_download "https://civitai.com/api/download/models/2435561?type=Model&format=SafeTensor&size=pruned&fp=fp16" \
  "${MODELS_DIR}/checkpoints/2435561_Photo4_fp16_pruned.safetensors" &
wait

# -----------------------------
# Optional character LoRA via env var
# -----------------------------
env_lora_download "CHAR_LORA_URL" &
wait

echo "[models] Downloads completed."

# -----------------------------
# Cache repos on persistent volume
# -----------------------------
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE"

# Extra bbox models repo
BBOX_DIR="${MODELS_DIR}/ultralytics/bbox"
ULTRA_REPO_DIR="${REPO_CACHE}/IIIIIIIII_ZIT_V3_Ultralytics"
UPDATE_MODELS="${UPDATE_MODELS:-0}"
BBOX_MARK="${PERSIST_DIR}/.bbox-models-copied"

if [ ! -d "${ULTRA_REPO_DIR}/.git" ]; then
  echo "[bbox] cloning ultralytics model repo (one-time)..."
  rm -rf "${ULTRA_REPO_DIR}"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 --progress \
    "https://github.com/rvspromotion-glitch/IIIIIIIII_ZIT_V3_Ultralytics.git" \
    "${ULTRA_REPO_DIR}"
elif [ "$UPDATE_MODELS" = "1" ]; then
  echo "[bbox] updating ultralytics model repo..."
  git -C "${ULTRA_REPO_DIR}" pull --rebase || true
else
  echo "[bbox] using cached ultralytics model repo (no pull)"
fi

if [ ! -f "$BBOX_MARK" ] || [ "$UPDATE_MODELS" = "1" ]; then
  echo "[bbox] syncing .pt files into ${BBOX_DIR}..."
  find "${ULTRA_REPO_DIR}" -type f -name "*.pt" -exec cp -f {} "${BBOX_DIR}/" \; || true
  touch "$BBOX_MARK"
fi

# Node pack repo (symlink into custom_nodes)
ZIT_REPO_DIR="${REPO_CACHE}/IIIIIIII_ZIT_V3"
UPDATE_NODES="${UPDATE_NODES:-0}"
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"

if [ ! -d "${ZIT_REPO_DIR}/.git" ]; then
  echo "[nodes] cloning node pack into cache (one-time)..."
  rm -rf "${ZIT_REPO_DIR}"
  GIT_TERMINAL_PROMPT=0 git clone --depth 1 --shallow-submodules --recurse-submodules --progress \
    "https://github.com/rvspromotion-glitch/IIIIIIII_ZIT_V3.git" \
    "${ZIT_REPO_DIR}"
  git -C "${ZIT_REPO_DIR}" submodule update --init --recursive --depth 1 || true
elif [ "$UPDATE_NODES" = "1" ]; then
  echo "[nodes] updating cached node pack..."
  git -C "${ZIT_REPO_DIR}" pull --rebase || true
  git -C "${ZIT_REPO_DIR}" submodule update --init --recursive || true
else
  echo "[nodes] using cached node pack (no pull)"
fi

echo "[nodes] creating symlinks in custom_nodes..."
for dir in "${ZIT_REPO_DIR}"/*; do
  [ -d "$dir" ] || continue
  node_name="$(basename "$dir")"
  case "$node_name" in .git|.github|__pycache__) continue ;; esac
  ln -sfn "$dir" "${CUSTOM_NODES}/${node_name}"
done

# Install node requirements once (constrained)
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
if [ "$INSTALL_NODE_REQS" = "1" ]; then
  if [ ! -f "$REQ_MARK" ] || [ "$UPDATE_NODES" = "1" ]; then
    echo "[pip] Installing node requirements (once, constrained)..."
    for dir in "${ZIT_REPO_DIR}"/*; do
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

# Final safety
pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" "numpy<2" "mediapipe==0.10.14" || true

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
