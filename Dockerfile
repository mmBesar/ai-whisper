# ── Stage 1: Build ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG TARGETARCH
ARG GGML_VULKAN=ON
ARG BUILD_DATE
ARG GIT_SHA
ARG VERSION

ENV DEBIAN_FRONTEND=noninteractive

# Base build deps always needed
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential cmake ninja-build git ca-certificates \
    libdrm-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Vulkan dev libs — only on amd64 and arm64
RUN if [ "$TARGETARCH" != "riscv64" ] && [ "$GGML_VULKAN" = "ON" ]; then \
        apt-get update -qq && apt-get install -y --no-install-recommends \
            libvulkan-dev glslc spirv-headers \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Clone whisper.cpp
RUN git clone --depth=1 https://github.com/ggml-org/whisper.cpp /src/whisper.cpp

# Build — arch-specific flags
RUN cd /src/whisper.cpp && \
    \
    # Set arch-specific march flags
    if [ "$TARGETARCH" = "arm64" ]; then \
        CPU=$(grep "CPU part" /proc/cpuinfo | head -1 | awk '{print $NF}' 2>/dev/null || echo "0x000"); \
        case "$CPU" in \
            0xd81) MARCH="-march=armv9-a+sve+sve2+i8mm+bf16" ;; \
            0xd0b) MARCH="-march=armv8.2-a+dotprod+fp16+i8mm" ;; \
            *)     MARCH="-march=armv8-a" ;; \
        esac; \
        EXTRA_C_FLAGS="$MARCH"; \
        EXTRA_CXX_FLAGS="$MARCH"; \
    else \
        EXTRA_C_FLAGS=""; \
        EXTRA_CXX_FLAGS=""; \
    fi && \
    \
    # RISC-V: no Vulkan, no special flags
    if [ "$TARGETARCH" = "riscv64" ]; then \
        VULKAN_FLAG="-DGGML_VULKAN=OFF"; \
    else \
        VULKAN_FLAG="-DGGML_VULKAN=${GGML_VULKAN}"; \
    fi && \
    \
    cmake -B build \
        $VULKAN_FLAG \
        -DWHISPER_FFMPEG=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$EXTRA_C_FLAGS" \
        -DCMAKE_CXX_FLAGS="$EXTRA_CXX_FLAGS" \
        -G Ninja && \
    cmake --build build --config Release

# Collect built artifacts
RUN mkdir -p /dist/bin && \
    cp /src/whisper.cpp/build/bin/whisper-cli    /dist/bin/ && \
    cp /src/whisper.cpp/build/bin/whisper-server  /dist/bin/ && \
    cp /src/whisper.cpp/build/ggml/src/libggml*.so*  /dist/bin/ && \
    cp /src/whisper.cpp/build/src/libwhisper*.so*     /dist/bin/ && \
    ( cp /src/whisper.cpp/build/ggml/src/ggml-vulkan/libggml-vulkan*.so* \
       /dist/bin/ 2>/dev/null || true ) && \
    strip --strip-unneeded /dist/bin/whisper-cli && \
    strip --strip-unneeded /dist/bin/whisper-server

# ── Stage 2: Runtime ─────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS runtime

ARG TARGETARCH
ARG BUILD_DATE
ARG GIT_SHA
ARG VERSION

LABEL org.opencontainers.image.title="ai-whisper"
LABEL org.opencontainers.image.description="Portable whisper.cpp server — Vulkan GPU on amd64/arm64, CPU on riscv64"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/mmBesar/ai-whisper"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ffmpeg \
    libdrm2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Vulkan runtime — only on amd64 and arm64
RUN if [ "$TARGETARCH" != "riscv64" ]; then \
        apt-get update -qq && apt-get install -y --no-install-recommends \
            libvulkan1 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Copy built binaries from builder stage
COPY --from=builder /dist/bin/ /app/bin/

# Copy web UI and samples
COPY public/ /app/public/
#COPY samples/ /app/samples/
COPY docker-entrypoint.sh /app/

RUN chmod +x /app/docker-entrypoint.sh

# ── Configuration via environment variables ──────────────────────────────────
# WHISPER_PORT      — server port              (default: 8080)
# WHISPER_THREADS   — threads to use           (default: auto)
# WHISPER_LANG      — default source language  (default: auto)
# WHISPER_MODEL     — model filename in /models (default: auto-detect)
# MODELS_DIR        — models mount point        (default: /models)

ENV WHISPER_PORT=8080 \
    WHISPER_THREADS=0 \
    WHISPER_LANG=auto \
    WHISPER_MODEL="" \
    MODELS_DIR=/models

# Models are always mounted — never bundled in the image
VOLUME /models

EXPOSE ${WHISPER_PORT}

# Run as nobody by default — override with --user uid:gid at runtime
USER nobody

ENTRYPOINT ["/app/docker-entrypoint.sh"]
