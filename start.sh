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
# Speed: persistent pip cache
# -----------------------------
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$PIP_CACHE_DIR"

PY="${PYTHON_BIN:-python3}"
PIP="$PY -m pip"

# -----------------------------
# Make git non-interactive
# -----------------------------
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
git config --global --unset-all http.https://github.com/.extraheader 2>/dev/null || true
git config --global --unset-all credential.helper 2>/dev/null || true

# -----------------------------
# Constraints (keep environment stable)
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
opencv-python<4.12
protobuf<5
transformers==4.39.3
tokenizers==0.15.2
mediapipe==0.10.14
safetensors
sageattention
EOF

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

# -----------------------------
# Detect CUDA tag and pin torch stack to a compatible known-good set
# - CUDA 12.1 -> cu121 -> torch 2.4.1 / tv 0.19.1 / ta 2.4.1
# - CUDA 12.8 -> cu128 -> torch 2.9.1 / tv 0.24.1 / ta 2.9.1
# -----------------------------
echo "==================================="
echo "Pinning torch stack"
echo "==================================="

CUDA_TAG="cu121"
if command -v nvcc >/dev/null 2>&1; then
  # nvcc prints "release 12.X"
  CUDA_REL="$(nvcc --version 2>/dev/null | awk '/release/ {print $6}' | tr -d ',' || true)"
  case "$CUDA_REL" in
    12.8*) CUDA_TAG="cu128" ;;
    12.7*) CUDA_TAG="cu128" ;;
    12.6*) CUDA_TAG="cu128" ;;
    12.5*) CUDA_TAG="cu128" ;;
    12.4*) CUDA_TAG="cu124" ;;
    12.3*) CUDA_TAG="cu121" ;;
    12.2*) CUDA_TAG="cu121" ;;
    12.1*) CUDA_TAG="cu121" ;;
    11.8*) CUDA_TAG="cu118" ;;
    *) CUDA_TAG="cu121" ;;
  esac
fi

TORCH_VER="2.4.1"
TORCHAUDIO_VER="2.4.1"
TORCHVISION_VER="0.19.1"

case "$CUDA_TAG" in
  cu128)
    TORCH_VER="2.9.1"
    TORCHAUDIO_VER="2.9.1"
    TORCHVISION_VER="0.24.1"
    ;;
  cu124)
    # if you ever run a cu124 base, use 2.6.0 family (safe default)
    TORCH_VER="2.6.0"
    TORCHAUDIO_VER="2.6.0"
    TORCHVISION_VER="0.21.0"
    ;;
  cu118)
    TORCH_VER="2.4.1"
    TORCHAUDIO_VER="2.4.1"
    TORCHVISION_VER="0.19.1"
    ;;
  *)
    TORCH_VER="2.4.1"
    TORCHAUDIO_VER="2.4.1"
    TORCHVISION_VER="0.19.1"
    ;;
esac

echo "[torch] cuda_tag=${CUDA_TAG}"
echo "[torch] torch=${TORCH_VER}+${CUDA_TAG}"
echo "[torch] torchvision=${TORCHVISION_VER}+${CUDA_TAG}"
echo "[torch] torchaudio=${TORCHAUDIO_VER}+${CUDA_TAG}"

# Remove any mismatched binaries first
$PIP uninstall -y torch torchvision torchaudio >/dev/null 2>&1 || true

# Install pinned stack (no deps to avoid surprise upgrades)
$PIP install -U --no-deps \
  "torch==${TORCH_VER}+${CUDA_TAG}" \
  "torchvision==${TORCHVISION_VER}+${CUDA_TAG}" \
  "torchaudio==${TORCHAUDIO_VER}+${CUDA_TAG}" \
  --index-url "https://download.pytorch.org/whl/${CUDA_TAG}"

# -----------------------------
# Now install constrained python deps (these were causing your pytree error)
# -----------------------------
echo "==================================="
echo "Installing constrained deps"
echo "==================================="

$PIP install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" \
  "opencv-python<4.12" \
  "protobuf<5" \
  "transformers==4.39.3" \
  "tokenizers==0.15.2" \
  "safetensors" \
  "mediapipe==0.10.14" \
  "sageattention" || true

# Manager style deps you saw during "Try fix" (safe to preinstall)
$PIP install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "ftfy" \
  "accelerate>=1.2.1" \
  "einops" \
  "diffusers>=0.33.0" \
  "librosa>=0.9.0" \
  "tqdm>=4.62.0" \
  "numba" \
  "soundfile" || true

echo "[debug] Versions:"
$PY - <<'PY'
import sys
print("python:", sys.version)
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy as np
print("numpy:", np.__version__)
try:
  import cv2
  print("opencv:", cv2.__version__)
except Exception as e:
  print("opencv: not available:", e)
try:
  import torchaudio
  print("torchaudio:", torchaudio.__version__)
except Exception as e:
  print("torchaudio import failed:", e)
try:
  import torchvision
  print("torchvision:", torchvision.__version__)
except Exception as e:
  print("torchvision import failed:", e)
import transformers
print("transformers:", transformers.__version__)
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

  curl -L --fail --retry 10 --retry-delay 2 -C - \
    -A "Mozilla/5.0" \
    -o "$out" "$url"

  if file "$out" | grep -qi "HTML"; then
    echo "[lora] ERROR: got HTML instead of model. Removing $out"
    rm -f "$out"
    return 1
  fi
}

# Install node requirements but never allow torch/numpy/transformers/opencv to be changed
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf|opencv-python)([<=> ].*)?$' "$req" > "$tmpreq" || true
  $PIP install -q --prefer-binary -c "$CONSTRAINTS_FILE" -r "$tmpreq" || true
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

# -----------------------------
# Custom nodes: clone + install (cached)
# -----------------------------
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE" "$CUSTOM_NODES"

UPDATE_NODES="${UPDATE_NODES:-0}"
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed.v2"

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

# Impact / Ultralytics
clone_or_update "ComfyUI-Impact-Pack"         "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
clone_or_update "ComfyUI-Impact-Subpack"      "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"

# Kijai + Video
clone_or_update "ComfyUI-KJNodes"             "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_or_update "ComfyUI-VideoHelperSuite"    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_update "ComfyUI-WanVideoWrapper"     "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"

# GGUF / Essentials / Masks
clone_or_update "ComfyUI-GGUF"                "https://github.com/city96/ComfyUI-GGUF.git"
clone_or_update "ComfyUI_essentials"          "https://github.com/cubiq/ComfyUI_essentials.git"
clone_or_update "a-person-mask-generator"     "https://github.com/djbielejeski/a-person-mask-generator.git"

# Scripts / Aux / rgthree
clone_or_update "ComfyUI-Custom-Scripts"      "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
clone_or_update "comfyui_controlnet_aux"      "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
clone_or_update "rgthree-comfy"               "https://github.com/rgthree/rgthree-comfy.git"

# RIFE / Interpolation
clone_or_update "ComfyUI-Frame-Interpolation" "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"

# Extras you added
clone_or_update "RES4LYF"                     "https://github.com/ClownsharkBatwing/RES4LYF.git"
clone_or_update "DJZ-Nodes"                   "https://github.com/MushroomFleet/DJZ-Nodes.git"

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

# Final re-assert pins (prevents nodes from drifting torch/numpy/transformers)
$PIP install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" "opencv-python<4.12" "protobuf<5" "transformers==4.39.3" "tokenizers==0.15.2" "mediapipe==0.10.14" "sageattention" || true

echo "[debug] Final torch stack:"
$PY - <<'PY'
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy as np
print("numpy:", np.__version__)
try:
  import torchaudio
  print("torchaudio:", torchaudio.__version__)
except Exception as e:
  print("torchaudio import failed:", e)
try:
  import torchvision
  print("torchvision:", torchvision.__version__)
except Exception as e:
  print("torchvision import failed:", e)
PY

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
exec $PY main.py --listen 0.0.0.0 --port 8188
