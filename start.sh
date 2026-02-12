#!/usr/bin/env bash
set -euo pipefail

STARTUP_START=$(date +%s)

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

# Fix DNS resolution issues
echo "[network] Checking DNS configuration..."
echo "[network] Current /etc/resolv.conf:"
cat /etc/resolv.conf

# Add Google DNS if not present
if ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
  echo "[network] Adding Google DNS to /etc/resolv.conf..."
  {
    echo "nameserver 8.8.8.8"
    echo "nameserver 8.8.4.4"
    echo "nameserver 1.1.1.1"
  } >> /etc/resolv.conf
  echo "[network] Updated /etc/resolv.conf:"
  cat /etc/resolv.conf
fi

# Test DNS resolution with multiple methods
echo "[network] Testing DNS resolution..."
if command -v nslookup >/dev/null 2>&1; then
  if nslookup pypi.org >/dev/null 2>&1; then
    echo "[network] DNS resolution working (nslookup test passed)"
  else
    echo "[network] WARNING: nslookup test failed"
  fi
fi

if command -v ping >/dev/null 2>&1; then
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "[network] Basic connectivity OK (ping 8.8.8.8 successful)"
  else
    echo "[network] WARNING: Cannot ping 8.8.8.8"
  fi
fi

# Try to resolve pypi.org using getent
if command -v getent >/dev/null 2>&1; then
  if getent hosts pypi.org >/dev/null 2>&1; then
    echo "[network] DNS working (getent hosts pypi.org successful)"
  else
    echo "[network] WARNING: getent hosts pypi.org failed"
  fi
fi

# Wait for network to be ready before continuing (critical for RunPod timing issues)
echo "[network] Waiting for network readiness..."
MAX_WAIT=30
WAIT_COUNT=0
while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
  if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && \
     (getent hosts pypi.org >/dev/null 2>&1 || nslookup pypi.org >/dev/null 2>&1); then
    echo "[network] Network is ready!"
    break
  fi
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ $WAIT_COUNT -lt $MAX_WAIT ]; then
    echo "[network] Network not ready, waiting... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 1
  else
    echo "[network] WARNING: Network still not ready after ${MAX_WAIT}s, proceeding anyway"
  fi
done

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"

# Persistent RunPod volume
PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-volume}"

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
# Speed: persistent pip cache + optimizations
# -----------------------------
export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
export PYTHONDONTWRITEBYTECODE=1
export PYTHONUNBUFFERED=1
mkdir -p "$PIP_CACHE_DIR"

PY="${PYTHON_BIN:-python3}"
PIP="$PY -m pip"

# -----------------------------
# Hard constraints (prevents numpy2 / transformers drift)
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
opencv-python<4.12
protobuf<5
transformers>=4.39.3
mediapipe==0.10.14
sageattention
EOF

export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

# PyTorch and all deps are pre-installed in Dockerfile - just verify versions
echo "[pip] Verifying pre-installed PyTorch stack..."

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
  import transformers
  print("transformers:", transformers.__version__)
except:
  print("transformers: not installed")
try:
  import mediapipe
  print("mediapipe:", mediapipe.__version__)
except:
  print("mediapipe: not installed")
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

  # Speed: use aria2c with optimized settings for RunPod network
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -c -x 16 -s 16 -k 1M \
      --max-connection-per-server=16 \
      --min-split-size=1M \
      --allow-overwrite=true \
      --file-allocation=none \
      --retry-wait=2 \
      --max-tries=8 \
      --timeout=60 \
      -d "$(dirname "$out")" -o "$(basename "$out")" \
      "$url" 2>&1 | grep -v "^Download Results:" || true
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -L --fail --retry 8 --retry-delay 2 --max-time 300 -C - -o "$out" "$url"
  else
    wget -c -O "$out" "$url"
  fi
}

# Install node requirements but never allow torch stack / numpy / transformers to be changed
safe_pip_install_req() {
  local req="$1"
  [ -f "$req" ] || return 0

  # Filter lines that must never override global pins
  local tmpreq
  tmpreq="$(mktemp)"
  grep -viE '^(torch|torchvision|torchaudio|numpy|transformers|tokenizers|protobuf)([<=> ].*)?$' "$req" > "$tmpreq" || true

  # Retry with exponential backoff
  local retries=3
  local delay=2
  for ((i=1; i<=retries; i++)); do
    if $PIP install -q --prefer-binary --retries 5 --timeout 60 \
      -c "$CONSTRAINTS_FILE" -r "$tmpreq"; then
      rm -f "$tmpreq"
      return 0
    fi
    if [ $i -lt $retries ]; then
      echo "  [pip] Retry $i/$retries failed, waiting ${delay}s..."
      sleep $delay
      delay=$((delay * 2))
    fi
  done

  echo "  [pip] WARNING: Failed to install requirements from $req"
  rm -f "$tmpreq"
  return 0
}

# -----------------------------
# Model directories
# -----------------------------
echo "[models] Creating model directories..."
mkdir -p \
  "${MODELS_DIR}/checkpoints" \
  "${MODELS_DIR}/clip" \
  "${MODELS_DIR}/clip_vision" \
  "${MODELS_DIR}/controlnet" \
  "${MODELS_DIR}/detection" \
  "${MODELS_DIR}/diffusion_models" \
  "${MODELS_DIR}/embeddings" \
  "${MODELS_DIR}/loras" \
  "${MODELS_DIR}/onnx" \
  "${MODELS_DIR}/unet" \
  "${MODELS_DIR}/upscale_models" \
  "${MODELS_DIR}/vae" \
  "${MODELS_DIR}/vae/pixel_space"

# -----------------------------
# Download required models (in parallel)
# -----------------------------
echo "[models] Downloading required models..."

# Z-Image Turbo models (FLUX/SANA workflow)
download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/diffusion_models/z_image_turbo_bf16.safetensors" \
  "${MODELS_DIR}/diffusion_models/z_image_turbo_bf16.safetensors" &

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
  "${MODELS_DIR}/vae/ae.safetensors" &

# Also symlink to pixel_space subdirectory (some workflows look there)
mkdir -p "${MODELS_DIR}/vae/pixel_space"
ln -sf "../ae.safetensors" "${MODELS_DIR}/vae/pixel_space/z-index-ae.safetensors" 2>/dev/null || true

download "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/text_encoders/qwen_3_4b.safetensors" \
  "${MODELS_DIR}/clip/qwen_3_4b.safetensors" &

# Upscale models - SkinDiffDetail (CORRECT: 1x not ix)
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/1x-ITF-SkinDiffDetail-Lite-v1.pth" \
  "${MODELS_DIR}/upscale_models/1x-ITF-SkinDiffDetail-Lite-v1.pth" &

# SOTA Upscale models for realism and skin detail
# RealESRGAN 4x+ - Best overall for photos, enhances textures and minimizes noise
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/RealESRGAN_x4plus.pth" \
  "${MODELS_DIR}/upscale_models/RealESRGAN_x4plus.pth" &

# 4x-UltraSharp - Sharp detail for realistic images
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x-UltraSharp.pth" \
  "${MODELS_DIR}/upscale_models/4x-UltraSharp.pth" &

# 4x-Foolhardy Remacri - Superior texture reconstruction
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_foolhardy_Remacri.pth" \
  "${MODELS_DIR}/upscale_models/4x_foolhardy_Remacri.pth" &

# NMKD Superscale - Perfect for clean real-world images
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4x_NMKD-Superscale-SP_178000_G.pth" \
  "${MODELS_DIR}/upscale_models/4x_NMKD-Superscale-SP_178000_G.pth" &

# 4xNomos8kDAT - High-quality advanced upscaling (trained on 8K data)
download "https://huggingface.co/uwg/upscaler/resolve/main/ESRGAN/4xNomos8kDAT.pth" \
  "${MODELS_DIR}/upscale_models/4xNomos8kDAT.pth" &

# ViTPose model (pose detection ONNX model) - requires both .onnx and .bin files
download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_model.onnx" &

download "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" \
  "${MODELS_DIR}/detection/vitpose_h_wholebody_data.bin" &

# YOLO detection model (YOLOv10m) - ONNX format from official ONNX Community
download "https://huggingface.co/onnx-community/yolov10m/resolve/main/onnx/model.onnx" \
  "${MODELS_DIR}/detection/yolov10m.onnx" &

# CLIP Vision model for WAN workflows (1.26 GB)
download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" \
  "${MODELS_DIR}/clip_vision/clip_vision_h.safetensors" &

# WAN 2.2 Animate models (for video generation workflows)
download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_animate_14B_bf16.safetensors" &

# WAN 2.2 low noise models (T2V and I2V)
download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" \
  "${MODELS_DIR}/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" \
  "${MODELS_DIR}/vae/wan_2.1_vae.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp16.safetensors" \
  "${MODELS_DIR}/clip/umt5_xxl_fp16.safetensors" &

# WAN low noise LoRAs (for improved video quality - 4 step distilled)
download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" \
  "${MODELS_DIR}/loras/wan2.2_t2v_lightx2v_4steps_lora_v1.1_low_noise.safetensors" &

download "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_repackaged/resolve/main/split_files/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" \
  "${MODELS_DIR}/loras/wan2.2_i2v_lightx2v_4steps_lora_v1_low_noise.safetensors" &

# Create symlinks for UNET directory (ComfyUI sometimes looks in unet/ instead of diffusion_models/)
mkdir -p "${MODELS_DIR}/unet"
ln -sf "../diffusion_models/z_image_turbo_bf16.safetensors" "${MODELS_DIR}/unet/z_image_turbo_bf16.safetensors" 2>/dev/null || true

wait
echo "[models] Model downloads completed"

# -----------------------------
# Character LoRA download (via environment variable)
# -----------------------------
if [ -n "${CHAR_LORA_URL:-}" ]; then
  echo "[models] Character LoRA URL provided, downloading..."
  # Extract filename from URL or use default
  CHAR_LORA_FILENAME=$(basename "$CHAR_LORA_URL" | sed 's/\?.*$//')
  if [ -z "$CHAR_LORA_FILENAME" ] || [[ "$CHAR_LORA_FILENAME" != *.* ]]; then
    CHAR_LORA_FILENAME="character_lora.safetensors"
  fi

  download "$CHAR_LORA_URL" "${MODELS_DIR}/loras/${CHAR_LORA_FILENAME}"
  echo "[models] Character LoRA downloaded: ${CHAR_LORA_FILENAME}"
else
  echo "[models] No character LoRA URL provided (CHAR_LORA_URL not set)"
fi

# -----------------------------
# Cache custom nodes on persistent volume
# -----------------------------
REPO_CACHE="${PERSIST_DIR}/_repos"
mkdir -p "$REPO_CACHE"

UPDATE_NODES="${UPDATE_NODES:-0}"

clone_or_update() {
  local name="$1"
  local url="$2"
  local dest="${REPO_CACHE}/${name}"

  if [ ! -d "${dest}/.git" ]; then
    echo "[nodes] cloning ${name}..."
    rm -rf "$dest"

    # Retry git clone up to 3 times with delays
    local retries=3
    local delay=3
    for ((i=1; i<=retries; i++)); do
      if git -c http.extraHeader= -c credential.helper= -c http.postBuffer=524288000 \
           clone --depth 1 --single-branch --progress "$url" "$dest" 2>&1 | grep -v "Checking out files"; then
        echo "[nodes] Successfully cloned ${name}"
        break
      else
        if [ $i -lt $retries ]; then
          echo "[nodes] Clone attempt $i failed for ${name}, retrying in ${delay}s..."
          rm -rf "$dest"
          sleep $delay
          delay=$((delay * 2))
        else
          echo "[nodes] ERROR: Failed to clone ${name} after $retries attempts, skipping"
          rm -rf "$dest"
          return 0
        fi
      fi
    done
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

# Clone all custom nodes in parallel for maximum speed
echo "[nodes] Cloning/updating custom nodes in parallel batches..."

# Manager first (needed for dependency resolution)
clone_or_update "ComfyUI-Manager" "https://github.com/ltdrdata/ComfyUI-Manager.git"

# Parallel batches
(
  clone_or_update "ComfyUI-Impact-Pack" "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
  clone_or_update "ComfyUI-Impact-Subpack" "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
  clone_or_update "ComfyUI-KJNodes" "https://github.com/kijai/ComfyUI-KJNodes.git"
) &

(
  clone_or_update "ComfyUI-VideoHelperSuite" "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
  clone_or_update "ComfyUI-WanVideoWrapper" "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
  clone_or_update "ComfyUI-GGUF" "https://github.com/city96/ComfyUI-GGUF.git"
) &

(
  clone_or_update "ComfyUI_essentials" "https://github.com/cubiq/ComfyUI_essentials.git"
  clone_or_update "a-person-mask-generator" "https://github.com/djbielejeski/a-person-mask-generator.git"
  clone_or_update "ComfyUI-VFI" "https://github.com/Fannovel16/ComfyUI-VFI.git"
) &

(
  clone_or_update "ComfyUI-Custom-Scripts" "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
  clone_or_update "comfyui_controlnet_aux" "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
  clone_or_update "rgthree-comfy" "https://github.com/rgthree/rgthree-comfy.git"
) &

(
  clone_or_update "ComfyUI-Frame-Interpolation" "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
  clone_or_update "RES4LYF" "https://github.com/ClownsharkBatwing/RES4LYF.git"
  clone_or_update "DJZ-Nodes" "https://github.com/MushroomFleet/DJZ-Nodes.git"
) &

(
  clone_or_update "ComfyUI-WanAnimatePreprocess" "https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git"
  clone_or_update "ComfyUI-segment-anything-2" "https://github.com/kijai/ComfyUI-segment-anything-2.git"
  clone_or_update "comfyui-tensorops" "https://github.com/un-seen/comfyui-tensorops.git"
) &

(
  clone_or_update "ComfyUI-NovaNoiser" "https://github.com/Aloukik21/ComfyUI-NovaNoiser.git"
) &

wait

# Special handling for savezipi9 (has two subdirectories with custom nodes)
echo "[nodes] Installing savezipi9 custom nodes..."
SAVEZIP_CACHE="${REPO_CACHE}/savezipi9"
if [ ! -d "${SAVEZIP_CACHE}/.git" ]; then
  echo "[nodes] cloning savezipi9..."
  rm -rf "$SAVEZIP_CACHE"

  retries=3
  delay=3
  for ((i=1; i<=retries; i++)); do
    if git -c http.extraHeader= -c credential.helper= -c http.postBuffer=524288000 \
         clone --depth 1 --single-branch --progress "https://github.com/rvspromotion-glitch/savezipi9.git" "$SAVEZIP_CACHE" 2>&1 | grep -v "Checking out files"; then
      echo "[nodes] Successfully cloned savezipi9"
      break
    else
      if [ $i -lt $retries ]; then
        echo "[nodes] Clone attempt $i failed for savezipi9, retrying in ${delay}s..."
        rm -rf "$SAVEZIP_CACHE"
        sleep $delay
        delay=$((delay * 2))
      else
        echo "[nodes] ERROR: Failed to clone savezipi9 after $retries attempts, skipping"
        rm -rf "$SAVEZIP_CACHE"
      fi
    fi
  done
elif [ "$UPDATE_NODES" = "1" ]; then
  echo "[nodes] updating savezipi9..."
  git -C "$SAVEZIP_CACHE" pull --rebase || true
else
  echo "[nodes] cached savezipi9 (no pull)"
fi

# Symlink each subdirectory to custom_nodes (they each have __init__.py)
if [ -d "$SAVEZIP_CACHE" ]; then
  ln -sfn "${SAVEZIP_CACHE}/Save-ZIP-I9" "${CUSTOM_NODES}/Save-ZIP-I9"
  ln -sfn "${SAVEZIP_CACHE}/batch-utility-i9" "${CUSTOM_NODES}/batch-utility-i9"
  echo "[nodes] Linked Save-ZIP-I9 and batch-utility-i9 subdirectories"
fi

echo "[nodes] All custom nodes cloned/updated successfully"

# Install node requirements
INSTALL_NODE_REQS="${INSTALL_NODE_REQS:-1}"
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

STARTUP_END=$(date +%s)
STARTUP_DURATION=$((STARTUP_END - STARTUP_START))
echo "[startup] Total startup time: ${STARTUP_DURATION}s"
echo "==================================="

cd "${COMFY_DIR}"
exec $PY main.py --listen 0.0.0.0 --port 8188
