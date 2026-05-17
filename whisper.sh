#!/usr/bin/env bash

# ─────────────────────────────────────────────────────
# ai-whisper — Auto-detect launcher v4
# Supports: x86_64 Vulkan (AMD/Intel), x86_64 CPU, aarch64 A720, A76
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
    elif [[ -f "$SCRIPT_DIR/bin/amd64/cpu/whisper-cli" ]]; then
        BIN="$SCRIPT_DIR/bin/amd64/cpu"
        BACKEND="CPU only"
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
        BACKEND="Vulkan GPU" ;;
      0xd0b)
        BIN="$SCRIPT_DIR/bin/arm64/a76"
        CPU_NAME="Cortex-A76 (RK3588 / Raspberry Pi 5) — $THREADS cores"
        BACKEND="CPU only" ;;
      *)
        BIN="$SCRIPT_DIR/bin/arm64/a76"
        CPU_NAME="Unknown ARM64 — using A76 build — $THREADS cores"
        BACKEND="CPU only" ;;
    esac
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

# ── Try to create version-agnostic symlinks ───────────
# When binary needs libfoo.so.62 but system has libfoo.so.61,
# create a symlink libfoo.so.62 -> /usr/lib/.../libfoo.so.61 in our BIN dir
create_compat_symlinks() {
    local needed_lib="$1"   # e.g. libavformat.so.62
    local base_name="${needed_lib%%.*}"  # e.g. libavformat

    # Already in our bundle?
    [[ -f "$BIN/$needed_lib" || -L "$BIN/$needed_lib" ]] && return 0

    # Search system for any version of this library
    local system_lib
    system_lib=$(ldconfig -p 2>/dev/null | grep "${base_name}\.so\." | \
                 awk '{print $NF}' | head -1)

    if [[ -n "$system_lib" && -f "$system_lib" ]]; then
        ln -sf "$system_lib" "$BIN/$needed_lib" 2>/dev/null && \
            echo "  compat:  $needed_lib → $system_lib" && return 0
    fi
    return 1
}

# ── Check and fix dependencies ────────────────────────
check_deps() {
    # Get truly missing libs — filter out filename lines from ldd output
    local missing
    missing=$(LD_LIBRARY_PATH="$BIN" ldd "$BIN/whisper-cli" 2>/dev/null | \
              grep "not found" | \
              grep -v "^/" | \
              awk '{print $1}')

    [[ -z "$missing" ]] && return 0

    # First pass: try to create symlinks for version mismatches
    local still_missing=""
    while IFS= read -r lib; do
        [[ -z "$lib" ]] && continue
        if ! create_compat_symlinks "$lib"; then
            still_missing="$still_missing $lib"
        fi
    done <<< "$missing"

    still_missing=$(echo "$still_missing" | xargs)  # trim whitespace
    [[ -z "$still_missing" ]] && return 0

    # Second pass: report what truly can't be resolved
    local pm
    pm=$(detect_pkg_manager)

    echo ""
    echo "  ⚠  Missing system libraries"
    echo "  ────────────────────────────────────"
    for lib in $still_missing; do
        echo "  missing: $lib"
    done
    echo ""

    # Suggest install commands based on what's missing
    local need_ffmpeg=0
    local need_vulkan=0
    local need_x11=0

    for lib in $still_missing; do
        case "$lib" in
          libav*|libsw*) need_ffmpeg=1 ;;
          libvulkan*)    need_vulkan=1 ;;
          libX11*|libxcb*|libXext*) need_x11=1 ;;
        esac
    done

    echo "  Install the missing packages:"
    echo ""

    case "$pm" in
      dnf)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo dnf install ffmpeg-free"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo dnf install vulkan-loader"
        [[ $need_x11    -eq 1 ]] && echo "    sudo dnf install libX11 libxcb"
        ;;
      apt)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo apt install ffmpeg"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo apt install libvulkan1"
        [[ $need_x11    -eq 1 ]] && echo "    sudo apt install libx11-6 libxcb1"
        ;;
      pacman)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo pacman -S ffmpeg"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo pacman -S vulkan-icd-loader"
        [[ $need_x11    -eq 1 ]] && echo "    sudo pacman -S libx11 libxcb"
        ;;
      zypper)
        [[ $need_ffmpeg -eq 1 ]] && echo "    sudo zypper install ffmpeg"
        [[ $need_vulkan -eq 1 ]] && echo "    sudo zypper install libvulkan1"
        [[ $need_x11    -eq 1 ]] && echo "    sudo zypper install libX11-6 libxcb1"
        ;;
      *)
        echo "  Package manager not detected."
        echo "  Install ffmpeg and vulkan libraries for your distro."
        ;;
    esac

    echo ""
    echo "  After installing, run this script again."
    echo ""
    exit 1
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

# ── Print Info ────────────────────────────────────────
echo ""
echo "  ai-whisper — Local Transcription v4"
echo "  ────────────────────────────────────"
echo "  CPU     : $CPU_NAME"
echo "  Backend : $BACKEND"
echo "  RAM     : ${AVAIL_RAM_MB}MB available / ${TOTAL_RAM_MB}MB total"
echo "  Threads : $THREADS_USE"
echo "  Task    : $TASK"
echo "  Lang    : $LANG"
[[ -n "$OUTPUT_FORMAT" ]] && echo "  Output  : $OUTPUT_FORMAT"
echo ""

# ── Check + fix dependencies ──────────────────────────
check_deps

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
