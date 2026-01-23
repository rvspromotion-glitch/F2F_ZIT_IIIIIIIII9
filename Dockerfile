FROM runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV COMFYUI_PATH=/workspace/ComfyUI
ENV COMFYUI_BAKED=/opt/ComfyUI

RUN apt-get update && apt-get install -y \
    git wget curl aria2 \
    libgl1 libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Use compatible versions for PyTorch 2.8 + CUDA 12.8
RUN pip install --no-cache-dir "numpy<2"
RUN pip install --no-cache-dir --upgrade xformers --index-url https://download.pytorch.org/whl/cu128

RUN pip install --no-cache-dir ultralytics
RUN pip install --no-cache-dir jupyterlab
RUN pip install --no-cache-dir sentencepiece
RUN pip install --no-cache-dir protobuf
RUN pip install --no-cache-dir mediapipe==0.10.14
RUN pip install --no-cache-dir sageattention

# Bake ComfyUI into /opt (won't be hidden by /workspace mount)
RUN git clone https://github.com/comfyanonymous/ComfyUI.git /opt/ComfyUI && \
    pip install --no-cache-dir -r /opt/ComfyUI/requirements.txt

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8188 8888
CMD ["/start.sh"]
