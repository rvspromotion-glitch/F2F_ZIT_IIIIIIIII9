FROM runpod/pytorch:2.1.1-py3.10-cuda12.1.1-devel-ubuntu22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV COMFYUI_PATH=/workspace/ComfyUI
ENV COMFYUI_BAKED=/opt/ComfyUI

RUN apt-get update && apt-get install -y \
    git wget curl aria2 \
    libgl1 libglib2.0-0 \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

RUN pip install --no-cache-dir "numpy<2"
RUN pip install --no-cache-dir --upgrade xformers==0.0.23

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
