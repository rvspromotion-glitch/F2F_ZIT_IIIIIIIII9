# Use RunPod's official PyTorch 2.8 + CUDA 12.8 + Python 3.11 image (devel is only available variant)
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    COMFYUI_PATH=/workspace/ComfyUI \
    COMFYUI_BAKED=/opt/ComfyUI \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Single optimized layer: install packages, Python deps, ComfyUI, and aggressive cleanup
RUN apt-get update && apt-get install -y --no-install-recommends \
    git wget curl aria2 \
    libgl1 libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && pip install --no-cache-dir \
    "numpy<2" \
    ultralytics \
    sentencepiece \
    protobuf \
    mediapipe==0.10.14 \
    sageattention \
    && pip install --no-cache-dir --upgrade xformers --index-url https://download.pytorch.org/whl/cu128 \
    && git clone --depth 1 --single-branch https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI \
    && pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt \
    && rm -rf /root/.cache /tmp/* /var/tmp/* \
    && find /usr/local -type f -name '*.pyc' -delete \
    && find /usr/local -type d -name '__pycache__' -delete \
    && apt-get clean

WORKDIR /workspace

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888
CMD ["/start.sh"]
