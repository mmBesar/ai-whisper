#!/usr/bin/env bash

# ─────────────────────────────────────────────────────
# ai-whisper — Auto-detect launcher v5
# Supports: x86_64 Vulkan (AMD/Intel), x86_64 CPU, aarch64 A720, A76, riscv64
# Tasks   : transcribe, translate (Arabic→English), SRT subtitles, server
# ─────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$SCRIPT_DIR/models"

# ── Detect Architecture ───────────────────────────────
ARCH=$(uname -m)
THREADS=$(nproc)

if [[ "$ARCH" == "x86_64" ]]; then
    CPU_NAME="x86_64 — $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
    if [[ -f "$SCRIPT_DIR/bin/amd64/vulkan/whisper-cli" ]]; then
        BIN="$SCRIPT_DIR/bin/amd64/vulkan"
        BACKEND="Vulkan GPU"
        WANTS_GPU=1
    elif [[ -f "$SCRIPT_DIR/bin/amd64/cpu/whisper-cli" ]]; then
        BIN="$SCRIPT_DIR/bin/amd64/cpu"
        BACKEND="CPU only"
        WANTS_GPU=0
    else
        echo "  Error: No x86_64 binaries found in $SCRIPT_DIR/bin/amd64/"
        exit 1
    fi

elif [[ "$ARCH" == "aarch64" ]]; then
    CPU=$(grep "CPU part" /proc/cpuinfo | head -1 | awk '{print $NF}')
    case $CPU in
      0xd81)
        BIN="$SCRIPT_DIR/bin/arm64/a720"
        CPU_NAME="Cortex-A720 (Orange Pi 6 Plus) — $THREADS cores"
        BACKEND="Vulkan GPU"
        WANTS_GPU=1 ;;
      0xd0b)
        BIN="$SCRIPT_DIR/bin/arm64/a76"
        CPU_NAME="Cortex-A76 (RK3588 / Raspberry Pi 5) — $THREADS cores"
        BACKEND="Vulkan GPU"
        WANTS_GPU=1 ;;
      *)
        BIN="$SCRIPT_DIR/bin/arm64/a76"
        CPU_NAME="Unknown ARM64 — using A76 build — $THREADS cores"
        BACKEND="Vulkan GPU"
        WANTS_GPU=1 ;;
    esac

elif [[ "$ARCH" == "riscv64" ]]; then
    CPU_NAME="RISC-V64 — $(grep -m1 'Model' /proc/cpuinfo | cut -d: -f2 | xargs 2>/dev/null || echo 'unknown')"
    BIN="$SCRIPT_DIR/bin/riscv64/cpu"
    BACKEND="CPU only"
    WANTS_GPU=0
else
    echo "  Error: Unsupported architecture: $ARCH"
    exit 1
fi

# ── Detect Package Manager ────────────────────────────
detect_pkg_manager() {
    if   command -v dnf    &>/dev/null; then echo "dnf"
    elif command -v apt    &>/dev/null; then echo "apt"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v zypper &>/dev/null; then echo "zypper"
    else echo "unknown"
    fi
}

# ── Check dependencies ────────────────────────────────
check_deps() {
    local missing
    missing=$(LD_LIBRARY_PATH="$BIN" ldd "$BIN/whisper-cli" 2>/dev/null | \
              grep "not found" | grep -v "^/" | awk '{print $1}')
    [[ -z "$missing" ]] && return 0

    local pm
    pm=$(detect_pkg_manager)
    local need_ffmpeg=0 need_vulkan=0

    echo ""
    echo "  ⚠  Missing system libraries"
    echo "  ────────────────────────────────────"
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        echo "  missing: $lib"
        case "$lib" in
          libav*|libsw*) need_ffmpeg=1 ;;
          libvulkan*)    need_vulkan=1 ;;
        esac
    done <<< "$missing"
    echo ""
    echo "  Install:"
    case "$pm" in
      dnf)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo dnf install ffmpeg-free"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo dnf install vulkan-loader"
        ;;
      apt)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo apt install ffmpeg"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo apt install libvulkan1 mesa-vulkan-drivers"
        ;;
      pacman)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo pacman -S ffmpeg"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo pacman -S vulkan-icd-loader"
        ;;
      *)
        echo "  Install ffmpeg and vulkan libraries for your distro."
        ;;
    esac
    echo ""
    echo "  After installing, run this script again."
    echo ""
    exit 1
}

# ── Check Vulkan GPU access ───────────────────────────
check_vulkan() {
    [[ $WANTS_GPU -eq 0 ]] && return 0

    # Quick probe — run whisper-cli --help and check for "No devices found"
    local probe
    probe=$(LD_LIBRARY_PATH="$BIN" "$BIN/whisper-cli" --help 2>&1 | head -3)

    if echo "$probe" | grep -q "No devices found"; then
        echo ""
        echo "  ⚠  Vulkan GPU not accessible — falling back to CPU"
        echo "  ────────────────────────────────────────────────────"

        # Check render group
        if ! groups | grep -qw "render"; then
            echo ""
            echo "  Your user is not in the 'render' group."
            echo "  Fix with:"
            echo ""
            echo "    sudo usermod -aG render \$USER"
            echo "    # Then log out and back in, or run:"
            echo "    newgrp render"
            echo ""
        fi

        # Check ICD files
        if [[ ! -d /usr/share/vulkan/icd.d ]] || \
           [[ -z "$(ls /usr/share/vulkan/icd.d/*.json 2>/dev/null)" ]]; then
            local pm
            pm=$(detect_pkg_manager)
            echo "  No Vulkan ICD drivers found."
            echo "  Install GPU-specific Vulkan drivers:"
            case "$pm" in
              apt)
                echo "    AMD:   sudo apt install mesa-vulkan-drivers"
                echo "    Intel: sudo apt install mesa-vulkan-drivers"
                echo "    NVIDIA: sudo apt install vulkan-tools" ;;
              dnf)
                echo "    AMD:   sudo dnf install mesa-vulkan-drivers"
                echo "    Intel: sudo dnf install mesa-vulkan-drivers" ;;
            esac
            echo ""
        fi

        # Check /dev/dri permissions
        if [[ -e /dev/dri/renderD128 ]]; then
            local dri_group
            dri_group=$(stat -c '%G' /dev/dri/renderD128 2>/dev/null)
            if ! groups | grep -qw "$dri_group"; then
                echo "  /dev/dri/renderD128 requires group: $dri_group"
                echo "  Add yourself: sudo usermod -aG $dri_group \$USER"
                echo ""
            fi
        fi

        echo "  Continuing with CPU — GPU features unavailable."
        echo ""
        BACKEND="CPU only (Vulkan unavailable)"
    fi
}

# ── Setup ffmpeg PATH ─────────────────────────────────
# Prefer bundled static ffmpeg, fall back to system ffmpeg
setup_ffmpeg() {
    local ffmpeg_dir
    if [[ "$ARCH" == "x86_64" ]]; then
        ffmpeg_dir="$SCRIPT_DIR/bin/amd64"
    elif [[ "$ARCH" == "aarch64" ]]; then
        ffmpeg_dir="$SCRIPT_DIR/bin/arm64"
    else
        ffmpeg_dir=""
    fi

    if [[ -n "$ffmpeg_dir" && -x "$ffmpeg_dir/ffmpeg" ]]; then
        export PATH="$ffmpeg_dir:$PATH"
        FFMPEG_SOURCE="bundled"
    elif command -v ffmpeg &>/dev/null; then
        FFMPEG_SOURCE="system ($(ffmpeg -version 2>&1 | head -1 | awk '{print $3}'))"
    else
        FFMPEG_SOURCE="not found"
    fi
}

# ── Detect Available RAM ──────────────────────────────
TOTAL_RAM_MB=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
AVAIL_RAM_MB=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')

# ── Defaults ──────────────────────────────────────────
TASK="transcribe"
LANG="auto"
OUTPUT_FORMAT=""
INPUT_FILE=""
OUTPUT_FILE=""
MODE="cli"
PORT=8081
THREADS_USE=$THREADS

# ── Parse Arguments ───────────────────────────────────
for arg in "$@"; do
    case $arg in
        --translate)  TASK="translate" ;;
        --transcribe) TASK="transcribe" ;;
        --lang=*)     LANG="${arg#*=}" ;;
        --srt)        OUTPUT_FORMAT="srt" ;;
        --vtt)        OUTPUT_FORMAT="vtt" ;;
        --txt)        OUTPUT_FORMAT="txt" ;;
        --server)     MODE="server" ;;
        --port=*)     PORT="${arg#*=}" ;;
        --threads=*)  THREADS_USE="${arg#*=}" ;;
        --file=*)     INPUT_FILE="${arg#*=}" ;;
        --out=*)      OUTPUT_FILE="${arg#*=}" ;;
        --test)
            INPUT_FILE="$SCRIPT_DIR/samples/jfk.wav"
            LANG="en"
            ;;
        --help|-h)
            echo ""
            echo "  ai-whisper — Usage"
            echo "  ──────────────────────────────────────────"
            echo "  ./whisper.sh [options]"
            echo ""
            echo "  Modes:"
            echo "    --transcribe          Transcribe audio/video (default)"
            echo "    --translate           Translate to English"
            echo "    --server              Start whisper-server (web API)"
            echo "    --test                Quick self-test with built-in sample"
            echo ""
            echo "  Options:"
            echo "    --file=PATH           Input audio or video file"
            echo "    --lang=LANG           Source language (default: auto)"
            echo "                          Examples: ar, en, fr"
            echo "    --srt                 Output SRT subtitle file"
            echo "    --vtt                 Output VTT subtitle file"
            echo "    --txt                 Output plain text file"
            echo "    --out=PATH            Output file path (no extension)"
            echo "    --port=N              Server port (default: 8081)"
            echo "    --threads=N           Threads to use (default: all)"
            echo ""
            echo "  Examples:"
            echo "    ./whisper.sh --test"
            echo "    ./whisper.sh --file=video.mp4 --lang=ar"
            echo "    ./whisper.sh --file=video.mp4 --lang=ar --translate"
            echo "    ./whisper.sh --file=video.mp4 --lang=ar --srt --out=subtitles"
            echo "    ./whisper.sh --server --port=8081"
            echo ""
            exit 0
            ;;
    esac
done

# ── Run checks ────────────────────────────────────────
check_deps
check_vulkan
setup_ffmpeg

# ── Print Info ────────────────────────────────────────
echo ""
echo "  ai-whisper — Local Transcription v5"
echo "  ────────────────────────────────────"
echo "  CPU     : $CPU_NAME"
echo "  Backend : $BACKEND"
echo "  RAM     : ${AVAIL_RAM_MB}MB available / ${TOTAL_RAM_MB}MB total"
echo "  Threads : $THREADS_USE"
echo "  Task    : $TASK"
echo "  Lang    : $LANG"
echo "  ffmpeg  : $FFMPEG_SOURCE"
[[ -n "$OUTPUT_FORMAT" ]] && echo "  Output  : $OUTPUT_FORMAT"
echo ""

# ── RAM warning ───────────────────────────────────────
if [[ $AVAIL_RAM_MB -lt 3000 ]]; then
    echo "  ⚠  Low RAM: ${AVAIL_RAM_MB}MB available."
    echo "     large-v3-turbo needs ~2GB. Consider a smaller model."
    echo ""
fi

# ── List Available Models ─────────────────────────────
echo "  Available models:"
i=1
declare -a MODEL_LIST
for f in "$MODELS_DIR"/*.bin; do
    [[ -f "$f" ]] || continue
    SIZE=$(du -sh "$f" 2>/dev/null | cut -f1)
    NAME=$(basename "$f")
    LABEL=""
    case "$NAME" in
      *large-v3-turbo*) LABEL=" ← recommended (fast, multilingual)" ;;
      *large-v3*)       LABEL=" ← best quality & translation" ;;
      *medium*)         LABEL=" ← balanced" ;;
      *small*)          LABEL=" ← fast, less accurate" ;;
      *base*)           LABEL=" ← very fast, basic accuracy" ;;
      *tiny*)           LABEL=" ← fastest, lowest accuracy" ;;
    esac
    echo "    [$i] $NAME ($SIZE)$LABEL"
    MODEL_LIST+=("$f")
    ((i++))
done
echo ""

if [[ ${#MODEL_LIST[@]} -eq 0 ]]; then
    echo "  Error: No models found in $MODELS_DIR"
    echo "  Download: wget -c https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin -O models/ggml-large-v3-turbo.bin"
    exit 1
fi

# ── Select Model ──────────────────────────────────────
if [[ ${#MODEL_LIST[@]} -eq 1 ]]; then
    SELECTED_MODEL="${MODEL_LIST[0]}"
    echo "  Auto-selected: $(basename "$SELECTED_MODEL")"
else
    read -rp "  Select model number: " MODEL_NUM
    MODEL_IDX=$((MODEL_NUM - 1))
    SELECTED_MODEL="${MODEL_LIST[$MODEL_IDX]}"
    if [[ ! -f "$SELECTED_MODEL" ]]; then
        echo "  Error: Invalid selection."
        exit 1
    fi
fi

# ── Server Mode ───────────────────────────────────────
if [[ "$MODE" == "server" ]]; then
    mkdir -p "$SCRIPT_DIR/public"
    SELECTED_NAME=$(basename "$SELECTED_MODEL")
    JSON='{"models":['
    first=1
    for f in "$MODELS_DIR"/*.bin; do
        [[ -f "$f" ]] || continue
        NAME=$(basename "$f")
        IS_DEFAULT="false"
        [[ "$NAME" == "$SELECTED_NAME" ]] && IS_DEFAULT="true"
        [[ $first -eq 0 ]] && JSON+=','
        JSON+="{\"name\":\"$NAME\",\"default\":$IS_DEFAULT}"
        first=0
    done
    JSON+=']}'
    echo "$JSON" > "$SCRIPT_DIR/public/models.json"

    echo "  Model   : $(basename "$SELECTED_MODEL")"
    echo "  Starting whisper-server on port $PORT..."
    echo "  Web UI  : http://$(hostname -I | awk '{print $1}'):$PORT"
    echo ""

    LD_LIBRARY_PATH="$BIN" "$BIN/whisper-server" \
        -m "$SELECTED_MODEL" \
        -t "$THREADS_USE" \
        --host 0.0.0.0 \
        --port "$PORT" \
        --public "$SCRIPT_DIR/public" \
        --convert \
        --tmp-dir /tmp
    exit 0
fi

# ── CLI Mode ──────────────────────────────────────────
if [[ -z "$INPUT_FILE" ]]; then
    read -rp "  Input file path: " INPUT_FILE
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "  Error: File not found: $INPUT_FILE"
    exit 1
fi

echo ""
echo "  Processing : $INPUT_FILE"
echo "  Model      : $(basename "$SELECTED_MODEL")"
echo ""

CMD=("$BIN/whisper-cli")
CMD+=(-m "$SELECTED_MODEL")
CMD+=(-f "$INPUT_FILE")
CMD+=(-t "$THREADS_USE")

[[ "$LANG" != "auto" ]] && CMD+=(-l "$LANG")
[[ "$TASK" == "translate" ]] && CMD+=(-tr)

case "$OUTPUT_FORMAT" in
    srt) CMD+=(-osrt) ;;
    vtt) CMD+=(-ovtt) ;;
    txt) CMD+=(-otxt) ;;
esac

[[ -n "$OUTPUT_FILE" ]] && CMD+=(-of "$OUTPUT_FILE")

LD_LIBRARY_PATH="$BIN" "${CMD[@]}"
