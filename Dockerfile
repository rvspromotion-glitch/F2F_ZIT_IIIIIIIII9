# Use runtime instead of devel to save ~3-4GB (no CUDA dev tools needed at runtime)
FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-runtime-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive \
    COMFYUI_PATH=/workspace/ComfyUI \
    COMFYUI_BAKED=/opt/ComfyUI \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Single layer for system packages + Python deps + ComfyUI (reduces image size)
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
    && rm -rf /root/.cache /tmp/* /var/tmp/*

WORKDIR /workspace

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888
CMD ["/start.sh"]
