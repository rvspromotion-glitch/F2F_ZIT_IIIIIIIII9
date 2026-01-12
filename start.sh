#!/usr/bin/env bash
set -euo pipefail

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

PY="/usr/bin/python3"

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
# Non-interactive git
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
# Constraints: keep your working stack
# (Do NOT pin/upgrade torch or comfy_kitchen here)
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
opencv-python<4.12
protobuf<5
EOF

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

# Re-assert only the safe pins (no torch touches)
$PY -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" "opencv-python<4.12" "protobuf<5" || true

# Keep sageattention (you asked for it)
$PY -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "sageattention" || true

echo "[debug] Versions:"
$PY - <<'PY'
import sys
print("python:", sys.version)
import torch
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
import numpy
print("numpy:", numpy.__version__)
try:
    import cv2
    print("opencv:", cv2.__version__)
except Exception as e:
    print("opencv: not available:", e)
try:
    import torchaudio
    print("torchaudio:", torchaudio.__version__)
except Exception as e:
    print("torchaudio: not available:", e)
try:
    import torchvision
    print("torchvision:", torchvision.__version__)
except Exception as e:
    print("torchvision: not available:", e)
PY

# -----------------------------
# IMPORTANT: Prevent restart loop from comfy_kitchen / fp8 extensions
# If comfy_kitchen is present and incompatible, remove it.
# (This avoids: torch.library.custom_op AttributeError)
# -----------------------------
echo "==================================="
echo "Disabling comfy_kitchen if present"
echo "==================================="
$PY -m pip uninstall -y comfy_kitchen >/dev/null 2>&1 || true

# -----------------------------
# Install "Manager style" deps (like your working Manager log)
# Use uv, but NEVER install torch from it.
# -----------------------------
echo "==================================="
echo "Installing common deps (uv pip like Manager)"
echo "==================================="

$PY -m pip install -q --upgrade uv || true

/usr/bin/python3 -m uv pip install ftfy || true
/usr/bin/python3 -m uv pip install "accelerate>=1.2.1" || true
/usr/bin/python3 -m uv pip install einops || true
/usr/bin/python3 -m uv pip install "diffusers>=0.33.0" || true
/usr/bin/python3 -m uv pip install "librosa>=0.9.0" || true
/usr/bin/python3 -m uv pip install "tqdm>=4.62.0" || true
/usr/bin/python3 -m uv pip install numba || true
/usr/bin/python3 -m uv pip install soundfile || true

# Extra audio/video helpers that commonly unblock DJZ/Wan nodes (non-fatal)
$PY -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  scipy pydub pyloudnorm sentencepiece ffmpeg-python av decord || true

echo "==================================="
echo "Fixing torch audio/vision ABI mismatch"
echo "==================================="

$PY - <<'PY'
import re, torch
v = torch.__version__  # e.g. 2.9.1+cu128
m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:\+(.+))?$", v)
if not m:
    raise SystemExit(f"Unexpected torch version: {v}")
maj, minor, patch, tag = m.group(1), m.group(2), m.group(3), m.group(4) or "cpu"
print(v)
print(f"{maj}.{minor}.{patch}")
print(tag)
PY

TORCH_FULL="$($PY - <<'PY'
import torch
print(torch.__version__)
PY
)"
TORCH_BASE="$($PY - <<'PY'
import re, torch
m = re.match(r"^(\d+)\.(\d+)\.(\d+)", torch.__version__)
print(".".join(m.groups()))
PY
)"
TORCH_MINOR="$($PY - <<'PY'
import re, torch
m = re.match(r"^(\d+)\.(\d+)\.(\d+)", torch.__version__)
print(m.group(2))
PY
)"
TORCH_PATCH="$($PY - <<'PY'
import re, torch
m = re.match(r"^(\d+)\.(\d+)\.(\d+)", torch.__version__)
print(m.group(3))
PY
)"
TORCH_TAG="$($PY - <<'PY'
import re, torch
m = re.match(r"^(\d+)\.(\d+)\.(\d+)(?:\+(.+))?$", torch.__version__)
print(m.group(4) or "cpu")
PY
)"

# torchvision mapping: torch 2.4.x -> tv 0.19.x, so tv_minor = torch_minor + 15
TV_MINOR="$($PY - <<PY
print(int("$TORCH_MINOR") + 15)
PY
)"
TV_VERSION="0.${TV_MINOR}.${TORCH_PATCH}+${TORCH_TAG}"

echo "[torch] torch_full=$TORCH_FULL"
echo "[torch] torch_tag=$TORCH_TAG"
echo "[torch] torchvision=$TV_VERSION"
echo "[torch] torchaudio=$TORCH_FULL"

# Remove mismatched binaries first
$PY -m pip uninstall -y torchaudio torchvision >/dev/null 2>&1 || true

# Pick correct PyTorch wheel index
if [ "$TORCH_TAG" = "cpu" ]; then
  PT_INDEX_URL="https://download.pytorch.org/whl/cpu"
else
  PT_INDEX_URL="https://download.pytorch.org/whl/${TORCH_TAG}"
fi

# Install matching wheels WITHOUT deps (so torch itself is not replaced)
$PY -m pip install -U --no-deps \
  "torchaudio==${TORCH_FULL}" \
  "torchvision==${TV_VERSION}" \
  --index-url "$PT_INDEX_URL"

# Verify imports
$PY - <<'PY'
import torch
print("torch:", torch.__version__)
import torchaudio, torchvision
print("torchaudio:", torchaudio.__version__)
print("torchvision:", torchvision.__version__)
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
    echo "[lora] ERROR: got HTML instead of model. Removing $out"
    rm -f "$out"
    return 1
  fi
}

# Install node requirements but never allow torch/numpy/opencv to be changed.
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  local tmpreq
  tmpreq="$(mktemp)"

  # Block any line that could touch core stack
  grep -viE '^(torch|torchvision|torchaudio|numpy|opencv-python|protobuf|xformers|comfy_kitchen)([<=> ].*)?$' "$req" > "$tmpreq" || true

  $PY -m pip install -q --prefer-binary -c "$CONSTRAINTS_FILE" -r "$tmpreq" || true
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
echo "[models] Downloading required models..."

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
# Custom Nodes: clone + (optional) deps
# =============================
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE" "$CUSTOM_NODES"

UPDATE_NODES="${UPDATE_NODES:-0}"
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"

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
echo "Installing custom nodes"
echo "==================================="

# Manager + your list
clone_or_update "ComfyUI-Manager"             "https://github.com/ltdrdata/ComfyUI-Manager.git"
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
clone_or_update "ComfyUI-Frame-Interpolation" "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
clone_or_update "RES4LYF"                     "https://github.com/ClownsharkBatwing/RES4LYF.git"

# DJZ is blocked by Manager security, so we install it ourselves
clone_or_update "DJZ-Nodes"                   "https://github.com/MushroomFleet/DJZ-Nodes.git"

# Your earlier "RIFE VFI" repo was wrong.
# Correct repo for ComfyUI-VFI:
clone_or_update "ComfyUI-VFI"                 "https://github.com/Fannovel16/ComfyUI-Video-Frame-Interpolation.git"

# Install node requirements once (constrained)
REQ_MARK="${PERSIST_DIR}/.node-reqs-installed"
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

# Re-assert safe pins again at the end
$PY -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" "opencv-python<4.12" "protobuf<5" || true

# Final sanity: confirm torch stack still intact
echo "[debug] Final torch stack:"
$PY - <<'PY'
import torch, numpy
print("torch:", torch.__version__)
print("cuda:", torch.version.cuda)
print("numpy:", numpy.__version__)
import torchaudio, torchvision
print("torchaudio:", torchaudio.__version__)
print("torchvision:", torchvision.__version__)
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
