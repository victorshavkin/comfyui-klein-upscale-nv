# Multi-stage build for Flux.2 Klein tile-upscale serverless worker.
# Builder uses cuda-DEVEL (nvcc) to compile SageAttention for sm_120;
# final image uses cuda-RUNTIME (no toolkit) to keep the image smaller so the
# serverless worker can pull it within the cold-start window.
# Stack: Python 3.13 + Torch 2.9.0 + CUDA 13.0 + SageAttention (sm_120).
# Models live on a RunPod network volume (/runpod-volume/models/{unet,clip,vae,upscale_models}).

# ============================ Stage 1: builder ============================
# NOTE: keep these RUN lines byte-identical to the previous single-stage build
# so Docker reuses the cached layers (esp. the slow SageAttention compile).
FROM nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04 AS builder

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

# SageAttention from source, compiled for Blackwell (sm_120).
# CRITICAL: nvcc + CUDA_HOME must be on PATH, and the build must run via
# `python setup.py install` — `uv pip install git+...` does NOT propagate
# TORCH_CUDA_ARCH_LIST to the build subprocess, so it silently builds only
# sm80/sm89 and you get "CUDA error: no kernel image" on RTX 5090 at runtime.
# Verified on a Blackwell pod: this recipe makes sageattn/qk_int8_pv_fp8 work on sm_120.
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=/usr/local/cuda/bin:${PATH}
ENV TORCH_CUDA_ARCH_LIST=12.0
RUN uv pip install setuptools wheel && \
    git clone https://github.com/thu-ml/SageAttention.git /tmp/sage && \
    cd /tmp/sage && MAX_JOBS=1 python setup.py install && \
    cd / && rm -rf /tmp/sage

# Network-volume model path mapping (unet/clip/vae/upscale_models -> /runpod-volume/models/...)
WORKDIR /comfyui
ADD src/extra_model_paths.yaml ./
WORKDIR /

# Handler runtime deps
RUN uv pip install runpod requests websocket-client

# Custom nodes required by the workflow (no models baked in)
RUN comfy node install --exit-on-fail rgthree-comfy || comfy node install rgthree-comfy
RUN git clone https://github.com/Steudio/ComfyUI_Steudio /comfyui/custom_nodes/ComfyUI_Steudio
RUN git clone https://github.com/kijai/ComfyUI-KJNodes /comfyui/custom_nodes/ComfyUI-KJNodes \
    && (uv pip install -r /comfyui/custom_nodes/ComfyUI-KJNodes/requirements.txt || true)
RUN comfy node install --exit-on-fail comfyui-custom-scripts || comfy node install comfyui-custom-scripts
RUN comfy node install --exit-on-fail comfyui-easy-use || comfy node install comfyui-easy-use

# ============================ Stage 2: final ============================
# Runtime base — no CUDA toolkit/nvcc (torch ships its own CUDA libs). Smaller image.
FROM nvidia/cuda:13.0.3-cudnn-runtime-ubuntu24.04 AS final

ENV DEBIAN_FRONTEND=noninteractive
ENV PYTHONUNBUFFERED=1
ENV PIP_NO_INPUT=1

# Runtime system deps + python3.13 (the venv's interpreter needs it present)
RUN apt-get update && apt-get install -y software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa && apt-get update \
    && apt-get install -y \
        python3.13 python3.13-venv \
        git wget \
        libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 ffmpeg openssh-server \
    && apt-get autoremove -y && apt-get clean -y && rm -rf /var/lib/apt/lists/*

# Bring the built venv (torch + sage + deps) and ComfyUI (+ custom nodes, model paths)
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /comfyui /comfyui
# uv (handy at runtime for comfy-cli helper scripts)
COPY --from=builder /root/.local/bin/uv /usr/local/bin/uv
ENV PATH="/opt/venv/bin:${PATH}"

# App code + helper scripts
ADD src/start.sh src/network_volume.py handler.py test_input.json ./
RUN chmod +x /start.sh
COPY scripts/comfy-node-install.sh /usr/local/bin/comfy-node-install
COPY scripts/comfy-manager-set-mode.sh /usr/local/bin/comfy-manager-set-mode
RUN chmod +x /usr/local/bin/comfy-node-install /usr/local/bin/comfy-manager-set-mode

CMD ["/start.sh"]
