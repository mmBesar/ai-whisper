# ── Stage 1: Build ──────────────────────────────────────────────────────────
FROM ubuntu:24.04 AS builder

ARG TARGETARCH
ARG GGML_VULKAN=ON
ARG BUILD_DATE
ARG GIT_SHA
ARG VERSION

ENV DEBIAN_FRONTEND=noninteractive

# Base build deps — ca-certificates FIRST so git clone works under QEMU
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ca-certificates \
    build-essential cmake ninja-build git \
    libdrm-dev pkg-config \
    && update-ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Vulkan dev libs — amd64 and arm64 only
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
        apt-get update -qq && apt-get install -y --no-install-recommends \
            libvulkan-dev glslc spirv-headers \
        && rm -rf /var/lib/apt/lists/*; \
    fi

# Clone whisper.cpp
RUN git clone --depth=1 https://github.com/ggml-org/whisper.cpp /src/whisper.cpp

# ── amd64: Vulkan ────────────────────────────────────────────────────────────
RUN if [ "$TARGETARCH" = "amd64" ]; then \
        cd /src/whisper.cpp && \
        cmake -B build \
            -DGGML_VULKAN=ON \
            -DWHISPER_FFMPEG=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -G Ninja && \
        cmake --build build --config Release; \
    fi

# ── arm64: Vulkan, generic march (QEMU safe) ─────────────────────────────────
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        cd /src/whisper.cpp && \
        cmake -B build \
            -DGGML_VULKAN=ON \
            -DWHISPER_FFMPEG=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_FLAGS="-march=armv8-a" \
            -DCMAKE_CXX_FLAGS="-march=armv8-a" \
            -G Ninja && \
        cmake --build build --config Release; \
    fi

# ── riscv64: CPU only ────────────────────────────────────────────────────────
RUN if [ "$TARGETARCH" = "riscv64" ]; then \
        cd /src/whisper.cpp && \
        cmake -B build \
            -DGGML_VULKAN=OFF \
            -DGGML_RVV=OFF \
            -DWHISPER_FFMPEG=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_FLAGS="-Wno-error -Wno-pedantic -Wno-implicit-function-declaration" \
            -DCMAKE_CXX_FLAGS="-Wno-error -Wno-pedantic" \
            -G Ninja && \
        cmake --build build --config Release; \
    fi

# Collect binaries and libs
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
LABEL org.opencontainers.image.description="Portable whisper.cpp server — Vulkan on amd64/arm64, CPU on riscv64"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${GIT_SHA}"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/mmBesar/ai-whisper"
LABEL org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Base runtime deps
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ffmpeg \
    libdrm2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Vulkan runtime — amd64 and arm64 only
RUN if [ "$TARGETARCH" = "amd64" ] || [ "$TARGETARCH" = "arm64" ]; then \
        apt-get update -qq && apt-get install -y --no-install-recommends \
            libvulkan1 \
        && rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=builder /dist/bin/ /app/bin/
COPY public/              /app/public/
COPY samples/             /app/samples/
COPY docker-entrypoint.sh /app/
RUN chmod +x /app/docker-entrypoint.sh

ENV WHISPER_PORT=8080 \
    WHISPER_THREADS=0 \
    WHISPER_LANG=auto \
    WHISPER_MODEL="" \
    MODELS_DIR=/models

VOLUME /models
EXPOSE ${WHISPER_PORT}

USER nobody
ENTRYPOINT ["/app/docker-entrypoint.sh"]
