# Lightweight ComfyUI worker — models live on a RunPod network volume (/runpod-volume),
# NOT baked into the image. This keeps the image small and the build fast/reliable.
FROM runpod/worker-comfyui:5.8.4-base

# install custom nodes into comfyui (same set as the original, pinned where possible)
RUN comfy node install --exit-on-fail comfyui-gguf@1.1.10 --mode remote || (echo "WARN: comfyui-gguf@1.1.10 unavailable in registry, falling back to latest" >&2 && comfy node install --exit-on-fail comfyui-gguf --mode remote)
RUN comfy node install --exit-on-fail rgthree-comfy@1.0.2512112053 || (echo "WARN: rgthree-comfy@1.0.2512112053 unavailable in registry, falling back to latest" >&2 && comfy node install --exit-on-fail rgthree-comfy)
# Steudio: pin to latest (v2.0.5) — the workflow (KleinUpscaler.json) uses the new
# Divide and Conquer node signature (use_upscale_with_model param, 3 outputs incl. ui).
# The old pinned commit had an incompatible signature and broke the graph silently.
RUN git clone https://github.com/Steudio/ComfyUI_Steudio /comfyui/custom_nodes/ComfyUI_Steudio
# NOTE: comfyui-crystools removed — its "Get resolution" node failed to load and is not
# needed: the workflow's image-width lookup uses KJNodes' GetImageSizeAndCount instead.
RUN comfy node install --exit-on-fail comfyui-custom-scripts@1.2.5 || (echo "WARN: comfyui-custom-scripts@1.2.5 unavailable in registry, falling back to latest" >&2 && comfy node install --exit-on-fail comfyui-custom-scripts)
RUN comfy node install --exit-on-fail comfyui-easy-use@1.3.1 || (echo "WARN: comfyui-easy-use@1.3.1 unavailable in registry, falling back to latest" >&2 && comfy node install --exit-on-fail comfyui-easy-use)
RUN git clone https://github.com/kijai/ComfyUI-KJNodes /comfyui/custom_nodes/ComfyUI-KJNodes && cd /comfyui/custom_nodes/ComfyUI-KJNodes && (git checkout f91daf93293ab7fb28836159595a5b088c86313a 2>/dev/null || (git fetch origin f91daf93293ab7fb28836159595a5b088c86313a --depth=1 && git checkout f91daf93293ab7fb28836159595a5b088c86313a) || echo "WARN: commit f91daf93293ab7fb28836159595a5b088c86313a unreachable in https://github.com/kijai/ComfyUI-KJNodes, falling back to default branch HEAD")

# NOTE: models are served from the attached network volume at /runpod-volume/models/...
# worker-comfyui 5.8.4 auto-detects them; nothing is downloaded at build time.
