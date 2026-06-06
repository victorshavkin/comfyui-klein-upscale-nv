# Custom worker-comfyui build for Flux.2 Klein tile-upscale.
# Stack pinned to match the user's known-good local setup:
#   Python 3.13 + Torch 2.9.0 + CUDA 13.0 + SageAttention (built from source for Blackwell sm_120).
# Models live on a RunPod network volume (/runpod-volume/models/{unet,clip,vae,upscale_models}).
FROM nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV PIP_PREFER_BINARY=1
ENV PYTHONUNBUFFERED=1
ENV CMAKE_BUILD_PARALLEL_LEVEL=8

# Python 3.13 (deadsnakes) + system deps
RUN apt-get update && apt-get install -y software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa && apt-get update \
    && apt-get install -y \
        python3.13 python3.13-venv python3.13-dev \
        git wget curl \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg \
        openssh-server build-essential ninja-build \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# uv + isolated venv on Python 3.13
RUN wget -qO- https://astral.sh/uv/install.sh | sh \
    && ln -s /root/.local/bin/uv /usr/local/bin/uv \
    && ln -s /root/.local/bin/uvx /usr/local/bin/uvx \
    && uv venv --python 3.13 /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# comfy-cli to install ComfyUI
RUN uv pip install comfy-cli pip setuptools wheel

# Install ComfyUI (latest). Torch gets overridden to cu130 right after.
RUN /usr/bin/yes | comfy --workspace /comfyui install --version latest --nvidia

# Ensure ALL ComfyUI runtime deps are present (comfy-cli can miss some, e.g. the new
# asset-DB needs sqlalchemy/alembic). This may pull a default torch — overridden next.
RUN uv pip install -r /comfyui/requirements.txt

# Pin the WHOLE torch stack to matching cu130 builds (after requirements, so it wins).
# torchaudio/torchvision must match torch exactly or you get
# "undefined symbol: torch_library_impl" at ComfyUI startup.
RUN uv pip install --force-reinstall \
    torch==2.9.0 torchvision==0.24.0 torchaudio==2.9.0 \
    --index-url https://download.pytorch.org/whl/cu130

# SageAttention from source (PyPI only has 1.0.x; need 2.x for Blackwell sm_120).
# nvcc comes from the cuda devel base image.
ENV TORCH_CUDA_ARCH_LIST="12.0"
RUN uv pip install --no-build-isolation git+https://github.com/thu-ml/SageAttention.git \
    || (echo "WARN: SageAttention source build failed, falling back to PyPI" >&2 && uv pip install sageattention)

# Network-volume model path mapping (unet/clip/vae/upscale_models -> /runpod-volume/models/...)
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
WORKDIR /

# Handler runtime deps + app code
RUN uv pip install runpod requests websocket-client
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
RUN chmod +x /usr/local/bin/comfy-node-install
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-manager-set-mode
ENV PIP_NO_INPUT=1

# Custom nodes required by the workflow (no models baked in)
RUN comfy node install --exit-on-fail rgthree-comfy || comfy node install rgthree-comfy
RUN git clone https://github.com/Steudio/ComfyUI_Steudio /comfyui/custom_nodes/ComfyUI_Steudio
RUN git clone https://github.com/kijai/ComfyUI-KJNodes /comfyui/custom_nodes/ComfyUI-KJNodes \
    && (uv pip install -r /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt || true)
RUN comfy node install --exit-on-fail comfyui-custom-scripts || comfy node install comfyui-custom-scripts
RUN comfy node install --exit-on-fail comfyui-easy-use || comfy node install comfyui-easy-use

CMD ["/start.sh"]
