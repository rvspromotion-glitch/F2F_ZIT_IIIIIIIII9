#!/usr/bin/env bash
set -euo pipefail

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"

PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-slim}"
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
# Git: non-interactive
# -----------------------------
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
git config --global --unset-all http.https://github.com/.extraheader 2>/dev/null || true
git config --global --unset-all credential.helper 2>/dev/null || true

# -----------------------------
# Speed: persistent pip cache
# -----------------------------
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$PIP_CACHE_DIR"

# -----------------------------
# Hard pins to keep the environment stable
# - numpy<2 (many wheels still expect numpy1)
# - opencv<4.12 (opencv 4.12 wants numpy>=2)
# - transformers/tokenizers pinned (avoid pytree mismatch on older torch)
# - keep sageattention
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
protobuf<5
opencv-python<4.12
opencv-contrib-python<4.12
transformers==4.39.3
tokenizers==0.15.2
safetensors
mediapipe==0.10.14
sageattention
EOF

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

# Nuke problematic packages that crash ComfyUI on older torch (custom_op)
python3 -m pip uninstall -y comfy_kitchen >/dev/null 2>&1 || true

# If opencv 4.12 got preinstalled, remove it first so it can't fight numpy<2
python3 -m pip uninstall -y opencv-python opencv-contrib-python >/dev/null 2>&1 || true

# Reinstall pinned core deps (force)
python3 -m pip install -q --upgrade --force-reinstall --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" \
  "protobuf<5" \
  "opencv-python<4.12" \
  "opencv-contrib-python<4.12" \
  "transformers==4.39.3" \
  "tokenizers==0.15.2" \
  "safetensors" \
  "mediapipe==0.10.14" \
  "sageattention" || true

# -----------------------------
# Install the same "Try Fix" deps (but with our constraints active)
# -----------------------------
echo "==================================="
echo "Installing helper deps"
echo "==================================="

python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  ftfy \
  "accelerate>=1.2.1" \
  einops \
  "diffusers>=0.33.0" \
  "librosa>=0.9.0" \
  "tqdm>=4.62.0" \
  numba \
  soundfile || true

# Optional video helpers (non-fatal)
python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  ffmpeg-python av decord sentencepiece || true

# -----------------------------
# Align torchvision + torchaudio to the installed torch (ABI-safe)
# IMPORTANT: torchvision version is NOT equal to torch version.
# For torch 2.1.1 -> torchvision 0.16.1, torchaudio 2.1.1
# -----------------------------
echo "==================================="
echo "Aligning torchvision and torchaudio to torch"
echo "==================================="

python3 - <<'PY'
import re, torch
torch_full = torch.__version__              # e.g. 2.1.1+cu121
torch_base = torch_full.split("+")[0]       # e.g. 2.1.1
cuda = torch.version.cuda or ""             # e.g. 12.1
print(f"[torch] torch_full={torch_full}")
print(f"[torch] torch_base={torch_base}")
print(f"[torch] cuda={cuda}")

# Map torch -> torchvision (common pairs)
tv_map = {
  "2.1.0": "0.16.0",
  "2.1.1": "0.16.1",
  "2.2.0": "0.17.0",
  "2.2.1": "0.17.1",
  "2.3.0": "0.18.0",
  "2.3.1": "0.18.1",
  "2.4.0": "0.19.0",
  "2.4.1": "0.19.1",
  "2.5.0": "0.20.0",
  "2.5.1": "0.20.1",
}

tv = tv_map.get(torch_base)
if not tv:
  # Best effort: keep it running rather than crashing start.sh
  print(f"[torch] WARNING: unknown torch_base={torch_base}, skipping torchvision/torchaudio alignment.")
  raise SystemExit(0)

# Determine wheel index (cu121/cpu/etc)
pt_index = "cpu"
if cuda.startswith("12.1"):
  pt_index = "cu121"
elif cuda.startswith("11.8"):
  pt_index = "cu118"
elif cuda.startswith("12.4"):
  pt_index = "cu124"
elif cuda.startswith("12.8"):
  pt_index = "cu128"

print(f"[torch] torchvision={tv}")
print(f"[torch] torchaudio={torch_base}")
print(f"[torch] index={pt_index}")

print(tv)
print(torch_base)
print(pt_index)
PY

TV_VER="$(python3 - <<'PY'
import torch
torch_base = torch.__version__.split("+")[0]
tv_map = {
  "2.1.0": "0.16.0",
  "2.1.1": "0.16.1",
  "2.2.0": "0.17.0",
  "2.2.1": "0.17.1",
  "2.3.0": "0.18.0",
  "2.3.1": "0.18.1",
  "2.4.0": "0.19.0",
  "2.4.1": "0.19.1",
  "2.5.0": "0.20.0",
  "2.5.1": "0.20.1",
}
print(tv_map.get(torch_base, ""))
PY
)"
TORCH_BASE="$(python3 - <<'PY'
import torch
print(torch.__version__.split("+")[0])
PY
)"
CUDA_VER="$(python3 - <<'PY'
import torch
print(torch.version.cuda or "")
PY
)"

PT_INDEX="cpu"
if [[ "$CUDA_VER" == 12.1* ]]; then PT_INDEX="cu121"; fi
if [[ "$CUDA_VER" == 11.8* ]]; then PT_INDEX="cu118"; fi
if [[ "$CUDA_VER" == 12.4* ]]; then PT_INDEX="cu124"; fi
if [[ "$CUDA_VER" == 12.8* ]]; then PT_INDEX="cu128"; fi

if [ -n "${TV_VER}" ]; then
  echo "[torch] installing torchvision==${TV_VER}+${PT_INDEX} torchaudio==${TORCH_BASE}+${PT_INDEX}"
  python3 -m pip uninstall -y torchvision torchaudio >/dev/null 2>&1 || true

  if [ "$PT_INDEX" = "cpu" ]; then
    python3 -m pip install -q --upgrade --no-deps \
      "torchvision==${TV_VER}" \
      "torchaudio==${TORCH_BASE}" \
      --index-url "https://download.pytorch.org/whl/cpu" || true
  else
    python3 -m pip install -q --upgrade --no-deps \
      "torchvision==${TV_VER}+${PT_INDEX}" \
      "torchaudio==${TORCH_BASE}+${PT_INDEX}" \
      --index-url "https://download.pytorch.org/whl/${PT_INDEX}" || true
  fi
fi

# Do NOT import torchvision here (can trigger transformers/onnx paths and fail the script)
python3 - <<'PY' || true
import torch, numpy
print("[debug] torch:", torch.__version__)
print("[debug] cuda :", torch.version.cuda)
print("[debug] numpy:", numpy.__version__)
try:
  import torchaudio
  print("[debug] torchaudio:", torchaudio.__version__)
except Exception as e:
  print("[debug] torchaudio import failed:", e)
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
    aria2c -c -x 16 -s 16 -k 1M --allow-overwrite=true --file-allocation=none \
      -d "$(dirname "$out")" -o "$(basename "$out")" "$url"
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
  curl -L --fail --retry 10 --retry-delay 2 -C - "${header[@]}" -o "$out" "$url"
  if file "$out" | grep -qi "HTML"; then
    echo "[civitai] ERROR: got HTML instead of model. Removing $out"
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
  if [ -f "$out" ] && [ -s "$out" ]; then
    echo "[lora] exists: $out"
    return 0
  fi
  curl -L --fail --retry 10 --retry-delay 2 -C - -A "Mozilla/5.0" -o "$out" "$url"
  if file "$out" | grep -qi "HTML"; then
    echo "[lora] ERROR: got HTML instead of model. Removing $out"
    rm -f "$out"
    return 1
  fi
}

# Install node requirements but never allow torch stack / numpy / transformers to be changed.
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf|opencv-python|opencv-contrib-python)([<=> ].*)?$' \
    "$req" > "$tmpreq" || true

  python3 -m pip install -q --prefer-binary -c "$CONSTRAINTS_FILE" -r "$tmpreq" || true
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
  "${MODELS_DIR}/loras/1511445_Spread_i5XL.safetensors" &
civit_download "https://civitai.com/api/download/models/2435561?type=Model&format=SafeTensor&size=pruned&fp=fp16" \
  "${MODELS_DIR}/checkpoints/2435561_Photo4_fp16_pruned.safetensors" &
wait

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
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"

clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${REPO_CACHE}/${name}"

  if [ ! -d "${dest}/.git" ]; then
    echo "[nodes] cloning ${name}..."
    rm -rf "$dest"
    if ! git -c http.extraHeader= -c credential.helper= clone --depth 1 --progress "$url" "$dest"; then
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

  ln -sfn "$dest" "${CUSTOM_NODES}/${name}"
}

echo "==================================="
echo "Installing custom nodes (cached)"
echo "==================================="

# Manager
clone_or_update "ComfyUI-Manager"             "https://github.com/ltdrdata/ComfyUI-Manager.git"

# Your list
clone_or_update "ComfyUI-Impact-Pack"         "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
clone_or_update "ComfyUI-Impact-Subpack"      "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
clone_or_update "ComfyUI-KJNodes"             "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_or_update "ComfyUI-VideoHelperSuite"    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_update "ComfyUI-WanVideoWrapper"     "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
clone_or_update "ComfyUI-GGUF"                "https://github.com/city96/ComfyUI-GGUF.git"
clone_or_update "ComfyUI_essentials"          "https://github.com/cubiq/ComfyUI_essentials.git"
clone_or_update "a-person-mask-generator"     "https://github.com/djbielejeski/a-person-mask-generator.git"
clone_or_update "ComfyUI-Custom-Scripts"      "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
clone_or_update "comfyui_controlnet_aux"      "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
clone_or_update "rgthree-comfy"               "https://github.com/rgthree/rgthree-comfy.git"

# Extra nodes you added in screenshot
# RIFE VFI comes from Frame-Interpolation in practice
clone_or_update "ComfyUI-Frame-Interpolation" "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
clone_or_update "RES4LYF"                     "https://github.com/ClownsharkBatwing/RES4LYF.git"
clone_or_update "DJZ-Nodes"                   "https://github.com/MushroomFleet/DJZ-Nodes.git"

# Install requirements once (constrained)
if [ "$INSTALL_NODE_REQS" = "1" ]; then
  if [ ! -f "$REQ_MARK" ] || [ "$UPDATE_NODES" = "1" ]; then
    echo "[pip] Installing node requirements (once, constrained)..."
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

# Re-assert pins at end (in case any req tried to move them)
python3 -m pip uninstall -y comfy_kitchen >/dev/null 2>&1 || true
python3 -m pip uninstall -y opencv-python opencv-contrib-python >/dev/null 2>&1 || true

python3 -m pip install -q --upgrade --force-reinstall --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" \
  "protobuf<5" \
  "opencv-python<4.12" \
  "opencv-contrib-python<4.12" \
  "transformers==4.39.3" \
  "tokenizers==0.15.2" \
  "mediapipe==0.10.14" \
  "sageattention"

echo "[setup] Done."

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
