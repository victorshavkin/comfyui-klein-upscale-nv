# Klein Upscale (network-volume edition)

Lightweight ComfyUI serverless worker for the **Flux.2 Klein** tile-upscale workflow.

Unlike the baked-image version, **models are NOT in the image** — they live on a
RunPod **network volume** mounted at `/runpod-volume`. This keeps the image small
and the build fast and reliable.

## Models (on the network volume, not in the image)
Expected layout on the volume (`/runpod-volume/models/...`):
```
models/diffusion_models/flux-2-klein-9b-nvfp4.safetensors   (gated, black-forest-labs)
models/text_encoders/qwen_3_8b_fp8mixed.safetensors
models/vae/flux2_vae.safetensors                            (real Flux.2 VAE, Comfy-Org/flux2-dev)
models/upscale_models/4x_Struzan.pth
```

## Deploy on RunPod
1. Connect this repository at https://runpod.io/console/serverless ("Deploy from GitHub").
2. Create a serverless endpoint, branch `main`.
3. **Attach the network volume** that holds the models above.
4. Pick an RTX 5090 GPU.
5. Send requests with `api-workflow.json` (ComfyUI `/prompt` API shape).

## Files
- `Dockerfile` — lightweight worker (ComfyUI + custom nodes, no models)
- `workflow.json` — the raw workflow (ComfyUI UI format)
- `api-workflow.json` — API shape for serverless requests
