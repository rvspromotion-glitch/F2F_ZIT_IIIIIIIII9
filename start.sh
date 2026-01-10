#!/usr/bin/env bash
set -euo pipefail

trap 'echo "[fatal] start.sh failed on line $LINENO"; exit 1' ERR

echo "==================================="
echo "Starting ComfyUI Setup"
echo "==================================="

COMFY_DIR="${COMFYUI_PATH:-/workspace/ComfyUI}"
CUSTOM_NODES="${COMFY_DIR}/custom_nodes"
MODELS_DIR="${COMFY_DIR}/models"

PERSIST_DIR="${RUNPOD_VOLUME:-/workspace/runpod-slim}"
BAKED_DIR="${COMFYUI_BAKED:-/opt/ComfyUI}"

mkdir -p "$(dirname "$COMFY_DIR")" "$PERSIST_DIR"

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

export PIP_CACHE_DIR="${PERSIST_DIR}/.cache/pip"
export PIP_DISABLE_PIP_VERSION_CHECK=1
mkdir -p "$PIP_CACHE_DIR"

export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS=/bin/true
git config --global --unset-all http.https://github.com/.extraheader 2>/dev/null || true
git config --global --unset-all credential.helper 2>/dev/null || true

echo "[debug] python exe: $(python3 -c 'import sys; print(sys.executable)')"

# -----------------------------
# Minimal constraints (stop numpy2 and opencv4.12+ drift)
# -----------------------------
CONSTRAINTS_FILE="${PERSIST_DIR}/pip-constraints.txt"
cat > "$CONSTRAINTS_FILE" <<'EOF'
numpy<2
opencv-python<4.12
protobuf<5
EOF

echo "[pip] constraints:"
cat "$CONSTRAINTS_FILE"

# Enforce constraints first
python3 -m pip install -q --upgrade --force-reinstall --prefer-binary -c "$CONSTRAINTS_FILE" "numpy<2" || true
python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" "opencv-python<4.12" "protobuf<5" || true

# -----------------------------
# Install the same deps Manager "Try Fix" installed, but using the same python env
# -----------------------------
echo "==================================="
echo "Installing node deps"
echo "==================================="

python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  ftfy \
  einops \
  "diffusers>=0.33.0" \
  "accelerate>=1.2.1" \
  "librosa>=0.9.0" \
  "tqdm>=4.62.0" \
  numba \
  soundfile \
  sentencepiece || true

# Optional helpers for some video nodes (non fatal)
python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  ffmpeg-python av decord || true

# -----------------------------
# Fix torchaudio ABI mismatch (DJZ, WanVideoWrapper etc)
# Use torch version WITHOUT +cuXXX suffix
# -----------------------------
echo "==================================="
echo "Aligning torchvision and torchaudio to torch"
echo "==================================="

TORCH_VERSION_FULL="$(python3 - <<'PY'
import torch
print(torch.__version__)
PY
)"
TORCH_VERSION="${TORCH_VERSION_FULL%%+*}"

CUDA_VER="$(python3 - <<'PY'
import torch
print(torch.version.cuda or "")
PY
)"

PT_INDEX="cpu"
case "$CUDA_VER" in
  11.8*) PT_INDEX="cu118" ;;
  12.1*) PT_INDEX="cu121" ;;
  12.4*) PT_INDEX="cu124" ;;
  12.8*) PT_INDEX="cu128" ;;
  "")    PT_INDEX="cpu" ;;
  *)     PT_INDEX="cpu" ;;
esac

echo "[torch] torch_full=${TORCH_VERSION_FULL}"
echo "[torch] torch=${TORCH_VERSION}"
echo "[torch] cuda=${CUDA_VER}"
echo "[torch] index=${PT_INDEX}"

# Remove any mismatched builds
python3 -m pip uninstall -y torchaudio torchvision >/dev/null 2>&1 || true

# Reinstall matching builds. If this fails, do NOT crash the container.
if [ "$PT_INDEX" = "cpu" ]; then
  python3 -m pip install -q --upgrade --no-deps \
    "torchvision==${TORCH_VERSION}" \
    "torchaudio==${TORCH_VERSION}" \
    --index-url "https://download.pytorch.org/whl/cpu" || true
else
  python3 -m pip install -q --upgrade --no-deps \
    "torchvision==${TORCH_VERSION}" \
    "torchaudio==${TORCH_VERSION}" \
    --index-url "https://download.pytorch.org/whl/${PT_INDEX}" || true
fi

python3 - <<'PY' || true
import torch, numpy
print("torch:", torch.__version__)
print("numpy:", numpy.__version__)
try:
  import torchaudio
  print("torchaudio:", torchaudio.__version__)
except Exception as e:
  print("torchaudio import failed:", e)
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

# -----------------------------
# Model directories + downloads (unchanged)
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

# -----------------------------
# Custom nodes (cached clone + symlink)
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
echo "Installing custom nodes + Manager"
echo "==================================="

clone_or_update "ComfyUI-Manager"              "https://github.com/ltdrdata/ComfyUI-Manager.git"
clone_or_update "ComfyUI-Impact-Pack"          "https://github.com/ltdrdata/ComfyUI-Impact-Pack.git"
clone_or_update "ComfyUI-Impact-Subpack"       "https://github.com/ltdrdata/ComfyUI-Impact-Subpack.git"
clone_or_update "ComfyUI-KJNodes"              "https://github.com/kijai/ComfyUI-KJNodes.git"
clone_or_update "ComfyUI-VideoHelperSuite"     "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git"
clone_or_update "ComfyUI-WanVideoWrapper"      "https://github.com/kijai/ComfyUI-WanVideoWrapper.git"
clone_or_update "ComfyUI-GGUF"                 "https://github.com/city96/ComfyUI-GGUF.git"
clone_or_update "ComfyUI_essentials"           "https://github.com/cubiq/ComfyUI_essentials.git"
clone_or_update "a-person-mask-generator"      "https://github.com/djbielejeski/a-person-mask-generator.git"
clone_or_update "ComfyUI-VFI"                  "https://github.com/Fannovel16/ComfyUI-VFI.git"
clone_or_update "ComfyUI-Custom-Scripts"       "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
clone_or_update "comfyui_controlnet_aux"       "https://github.com/Fannovel16/comfyui_controlnet_aux.git"
clone_or_update "rgthree-comfy"                "https://github.com/rgthree/rgthree-comfy.git"
clone_or_update "ComfyUI-Frame-Interpolation"  "https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git"
clone_or_update "RES4LYF"                      "https://github.com/ClownsharkBatwing/RES4LYF.git"
clone_or_update "DJZ-Nodes"                    "https://github.com/MushroomFleet/DJZ-Nodes.git"

# Reassert constraints at end
python3 -m pip install -q --upgrade --prefer-binary -c "$CONSTRAINTS_FILE" \
  "numpy<2" "opencv-python<4.12" "protobuf<5" || true

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
