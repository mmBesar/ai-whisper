# ai-whisper

Portable [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — download, extract, run. No install needed.

Vulkan GPU acceleration on x86_64 and ARM64. CPU on RISC-V64. Built-in web UI and CLI.

---

## Portable binary

```bash
# Download latest release
wget https://github.com/mmBesar/ai-whisper/releases/latest/download/ai-whisper-latest.tar.gz
tar -xzf ai-whisper-latest.tar.gz
cd ai-whisper

# Download a model
mkdir -p models
wget -c "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
     -O models/ggml-large-v3-turbo.bin

# Quick self-test
./whisper.sh --test

# Start web server (open http://YOUR_IP:8082 from any device)
./whisper.sh --server --port=8082

# Transcribe Arabic video to SRT subtitles
./whisper.sh --file=video.mp4 --lang=ar --srt --out=subtitles
```

### Supported architectures

| Arch | Backend | Built on |
|---|---|---|
| x86_64 | Vulkan GPU | `ubuntu-24.04` native |
| ARM64 (Cortex-A720, Orange Pi 6 Plus) | Vulkan GPU | `ubuntu-24.04-arm` native |
| ARM64 (Cortex-A76, RK3588, Pi 5) | Vulkan GPU | `ubuntu-24.04-arm` native |
| RISC-V64 | CPU | `ubuntu-24.04-riscv` native (RISE) |

### Requirements

- GLIBC 2.39+ (Ubuntu 24.04+, Debian 13+, Fedora 40+)
- `ffmpeg` — bundled as static binary for amd64 and arm64, no install needed
- RISC-V64: install system `ffmpeg` once (`sudo apt install ffmpeg`)
- Vulkan GPU driver for GPU acceleration (open-source `amdgpu`/`radv` or `intel-media-driver`)

---

## Container image

Supports `linux/amd64`, `linux/arm64`, and `linux/riscv64` in a single multi-arch image.

```bash
# Pull (auto-selects correct arch)
podman pull ghcr.io/mmbesar/ai-whisper:latest

# Run — mount models, run as your own user
podman run -d \
  --name whisper \
  -p 8082:8080 \
  -v /path/to/models:/models:ro \
  --user $(id -u):$(id -g) \
  ghcr.io/mmbesar/ai-whisper:latest

# Open web UI
xdg-open http://localhost:8082
```

### On a RISC-V64 SBC (e.g. StarFive VisionFive 2, Milk-V Pioneer)

```bash
# Same command — the image contains a riscv64 layer automatically
podman pull ghcr.io/mmbesar/ai-whisper:latest
podman run -d \
  -p 8082:8080 \
  -v /path/to/models:/models:ro \
  --user $(id -u):$(id -g) \
  ghcr.io/mmbesar/ai-whisper:latest
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `WHISPER_PORT` | `8080` | Server port |
| `WHISPER_THREADS` | auto | CPU threads |
| `WHISPER_LANG` | `auto` | Default source language (e.g. `ar`, `en`) |
| `WHISPER_MODEL` | auto-detect | Model filename in `/models` |
| `MODELS_DIR` | `/models` | Models mount point |

Auto-detection order: `large-v3` → `large-v3-turbo` → `medium` → `small` → `base` → `tiny`

### Docker Compose

```yaml
services:
  whisper:
    image: ghcr.io/mmbesar/ai-whisper:latest
    ports:
      - "8082:8080"
    volumes:
      - /data/ai/models:/models:ro
    environment:
      WHISPER_THREADS: 8
      WHISPER_LANG: ar
    user: "1000:1000"
    restart: unless-stopped
```

---

## Models

Models are not bundled. Download from Hugging Face:

```bash
mkdir -p models

# Recommended — fast, multilingual (1.6GB)
wget -c "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" \
     -O models/ggml-large-v3-turbo.bin

# Best quality (3.0GB)
wget -c "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin" \
     -O models/ggml-large-v3.bin
```

| Model | Size | Best for |
|---|---|---|
| `ggml-large-v3-turbo` | 1.6 GB | Daily use, Arabic, all languages |
| `ggml-large-v3` | 3.0 GB | Best quality, translation |
| `ggml-medium` | 769 MB | Balanced, limited RAM |
| `ggml-small` | 244 MB | Fast, basic accuracy |

---

## Setup for RISC-V64 builds (RISE runners)

The RISC-V64 jobs use real bare-metal hardware via the [RISE Project](https://riseproject.dev/risc-v-runners/) — no QEMU.

**One-time setup:**
1. Go to [riseproject.dev/risc-v-runners](https://riseproject.dev/risc-v-runners/)
2. Install the RISE GitHub App on your account
3. The `runs-on: ubuntu-24.04-riscv` runner works automatically

---

## Building from source

Both workflows (`build.yml` and `container.yml`) trigger on version tags:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Or trigger manually: **Actions → Build Portable Binaries → Run workflow**
