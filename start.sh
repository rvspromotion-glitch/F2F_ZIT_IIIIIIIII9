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
transformers==4.39.3
tokenizers==0.15.2
mediapipe==0.10.14
sageattention
EOF

export PIP_CONSTRAINT="$CONSTRAINTS_FILE"

echo "[pip] Enforcing constraints:"
cat "$CONSTRAINTS_FILE"

# Detect CUDA tag from installed torch
CUDA_TAG=$(python3 -c "import torch; print('cu' + torch.version.cuda.replace('.', '')[:4] if torch.version.cuda else 'cpu')" 2>/dev/null || echo "cu128")
echo "[debug] Detected CUDA tag: $CUDA_TAG"

# PyTorch version logic
TORCH_VER="2.4.1"
TORCHAUDIO_VER="2.4.1"
TORCHVISION_VER="0.19.1"

case "$CUDA_TAG" in
  cu128)
    # PyTorch 2.8.0 is the stable version for CUDA 12.8
    TORCH_VER="2.8.0"
    TORCHAUDIO_VER="2.8.0"
    TORCHVISION_VER="0.23.0"
    ;;
  cu124)
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

echo "[pip] Target torch stack: torch=$TORCH_VER torchvision=$TORCHVISION_VER torchaudio=$TORCHAUDIO_VER"

# Install/update torch stack with retries
MAX_RETRIES=3
RETRY_COUNT=0
RETRY_DELAY=5

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  echo "[pip] Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES for torch stack..."

  if $PIP install -q --upgrade --prefer-binary \
    --index-url "https://download.pytorch.org/whl/${CUDA_TAG}" \
    --retries 5 --timeout 60 \
    -c "$CONSTRAINTS_FILE" \
    "torch==${TORCH_VER}" \
    "torchvision==${TORCHVISION_VER}" \
    "torchaudio==${TORCHAUDIO_VER}"; then
    echo "[pip] Torch stack installed successfully"
    break
  else
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "[pip] Install failed, retrying in ${RETRY_DELAY}s..."
      sleep $RETRY_DELAY
      RETRY_DELAY=$((RETRY_DELAY * 2))
    else
      echo "[pip] WARNING: Failed to install torch stack after $MAX_RETRIES attempts"
      echo "[pip] Continuing with existing torch installation"
    fi
  fi
done

# Manager style deps
$PIP install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "ftfy" \
  "accelerate>=1.2.1" \
  "einops" \
  "diffusers>=0.33.0" \
  "librosa>=0.9.0" \
  "tqdm>=4.62.0" \
  "numba" \
  "soundfile" || true

# Install xformers for PyTorch 2.8 + CUDA 12.8
if [ "$CUDA_TAG" = "cu128" ]; then
  echo "[pip] Installing xformers for PyTorch 2.8 + CUDA 12.8..."
  $PIP install -q --upgrade xformers --index-url https://download.pytorch.org/whl/cu128 || true
fi

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
    # Speed: use single-branch + shallow clone with optimized config
    if ! git -c http.extraHeader= -c credential.helper= -c http.postBuffer=524288000 \
         clone --depth 1 --single-branch --progress "$url" "$dest" 2>&1 | grep -v "Checking out files" || true; then
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

wait

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

STARTUP_END=$(date +%s)
STARTUP_DURATION=$((STARTUP_END - STARTUP_START))
echo "[startup] Total startup time: ${STARTUP_DURATION}s"
echo "==================================="

cd "${COMFY_DIR}"
exec $PY main.py --listen 0.0.0.0 --port 8188
