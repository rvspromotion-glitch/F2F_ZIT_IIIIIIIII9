#!/usr/bin/env bash
set -euo pipefail

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

echo "[debug] running: $0"

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

# Base pins (non-fatal if some wheels are missing on the image)
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

# -----------------------------
# Critical fix: ComfyUI comfy_kitchen requires torch >= 2.4
# Your template shows torch 2.1.1+cu121, which breaks at import time:
# AttributeError: torch.library has no attribute custom_op
# -----------------------------
NEED_TORCH_UPGRADE="$(
python3 - <<'PY'
import torch
v = torch.__version__.split("+")[0]
parts = v.split(".")
maj = int(parts[0]) if len(parts) > 0 else 0
minr = int(parts[1]) if len(parts) > 1 else 0
print("1" if (maj < 2 or (maj == 2 and minr < 4)) else "0")
PY
)"

echo "[torch] current: $(python3 -c 'import torch; print(torch.__version__)')"
echo "[torch] need_upgrade=${NEED_TORCH_UPGRADE}"

if [ "$NEED_TORCH_UPGRADE" = "1" ]; then
  echo "[torch] Upgrading torch stack to cu121..."
  pip install -q --upgrade --no-cache-dir --force-reinstall \
    --extra-index-url https://download.pytorch.org/whl/cu121 \
    "torch==2.4.1+cu121" "torchvision==0.19.1+cu121" "torchaudio==2.4.1+cu121"
fi

echo "[torch] after: $(python3 -c 'import torch; print(torch.__version__)')"

# -----------------------------
# Debug: versions
# -----------------------------
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
  local url_var="$1"      # env var name, e.g. CHAR_LORA_URL
  local filename="${2:-}" # optional output filename override
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

# Install node requirements but never allow torch stack / numpy / transformers to be changed.
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

# Final safety (non-fatal)
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
