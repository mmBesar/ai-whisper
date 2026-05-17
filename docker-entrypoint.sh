#!/bin/sh
set -e

BIN_DIR="/app/bin"
MODELS_DIR="${MODELS_DIR:-/models}"
PORT="${WHISPER_PORT:-8080}"
THREADS="${WHISPER_THREADS:-0}"
LANG="${WHISPER_LANG:-auto}"
MODEL="${WHISPER_MODEL:-}"

# ── Auto-detect threads ───────────────────────────────────────────────────────
if [ "$THREADS" = "0" ]; then
    THREADS=$(nproc 2>/dev/null || echo 4)
fi

# ── Auto-detect model ─────────────────────────────────────────────────────────
if [ -z "$MODEL" ]; then
    # Quality-ordered preference
    for preferred in \
        ggml-large-v3.bin \
        ggml-large-v3-turbo.bin \
        ggml-medium.bin \
        ggml-small.bin \
        ggml-base.bin \
        ggml-tiny.bin; do
        if [ -f "$MODELS_DIR/$preferred" ]; then
            MODEL="$MODELS_DIR/$preferred"
            break
        fi
    done
    # Fallback: first .bin found
    if [ -z "$MODEL" ]; then
        MODEL=$(find "$MODELS_DIR" -maxdepth 1 -name "*.bin" 2>/dev/null | sort | head -1)
    fi
fi

# ── No model found — helpful error ────────────────────────────────────────────
if [ -z "$MODEL" ] || [ ! -f "$MODEL" ]; then
    echo ""
    echo "  ✗ No model found in $MODELS_DIR"
    echo ""
    echo "  Mount a models directory containing a .bin model:"
    echo ""
    echo "  podman run -v /path/to/models:/models:ro \\"
    echo "    ghcr.io/mmbesar/ai-whisper:latest"
    echo ""
    echo "  Download a model first:"
    echo "  wget -c https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    echo ""
    exit 1
fi

# ── Generate models.json for the web UI dropdown ──────────────────────────────
mkdir -p /app/public
{
    printf '{"models":['
    first=1
    for f in "$MODELS_DIR"/*.bin; do
        [ -f "$f" ] || continue
        NAME=$(basename "$f")
        IS_DEFAULT="false"
        [ "$f" = "$MODEL" ] && IS_DEFAULT="true"
        [ $first -eq 0 ] && printf ','
        printf '{"name":"%s","default":%s}' "$NAME" "$IS_DEFAULT"
        first=0
    done
    printf ']}'
} > /app/public/models.json

# ── Detect architecture for display ───────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  BACKEND="Vulkan GPU (amd64)" ;;
    aarch64) BACKEND="Vulkan GPU (arm64)" ;;
    riscv64) BACKEND="CPU only (riscv64)" ;;
    *)       BACKEND="CPU ($ARCH)" ;;
esac

# ── Print startup info ────────────────────────────────────────────────────────
echo ""
echo "  ai-whisper container"
echo "  ────────────────────────────────────"
echo "  Image   : ghcr.io/mmbesar/ai-whisper"
echo "  Arch    : $ARCH — $BACKEND"
echo "  Model   : $(basename "$MODEL")"
echo "  Port    : $PORT"
echo "  Threads : $THREADS"
echo "  Lang    : $LANG"
echo "  Web UI  : http://0.0.0.0:$PORT"
echo ""

# ── Set library path ──────────────────────────────────────────────────────────
export LD_LIBRARY_PATH="$BIN_DIR"

# ── Launch whisper-server ─────────────────────────────────────────────────────
exec "$BIN_DIR/whisper-server" \
    -m "$MODEL" \
    -t "$THREADS" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --public /app/public \
    --convert \
    --tmp-dir /tmp
