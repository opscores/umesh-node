# syntax=docker/dockerfile:1.6
# ============================================================================
# Multi-stage Dockerfile for Umesh blockchain with CosmWasm support
# Cosmos SDK v0.54 + CosmWasm wasmvm v3.0.7
# Go 1.25.12 (go.mod requires 1.25.9)
# Ubuntu 26.04 LTS (stable, security-patched)
# Penta-Mode Architecture: Genesis + Joining + Validator + Sentry + RPC
# amd64-Only Production Build
# ============================================================================
# [INFO] WasmVM AOT cache configuration:
# Validator: tmpfs (volatile, AOT cache discarded on restart; prevents wasm cache
#            alongside validator private keys on persistent storage)
# Sentry/RPC: persistent volume (./data-*/wasm) — avoids contract recompilation
#            after restart, acceptable since sentry/rpc don't hold private keys.
# ============================================================================
# [INFO] Node initialization and tuning run on the host via `umeshctl`
# BEFORE the container starts. This image contains NO init/tune scripts.
# ============================================================================

# Тип сборки: umeshprep (генерация исходников через umesh-prep внутри контейнера, дефолт)
# или local (копирование локального src/umesh/)
ARG BUILD_TYPE=umeshprep

# ============================================================================
# Stage 0: Go toolchain (общий для скачивания umesh-prep и builder)
# ============================================================================
FROM docker.io/library/ubuntu:26.04 AS go-toolchain

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV GO_VERSION=1.25.12
ENV GOPATH=/go
ENV GOMODCACHE=/go/pkg/mod
ENV PATH=$GOPATH/bin:/usr/local/go/bin:$PATH

RUN apt-get update --allow-releaseinfo-change && apt-get install -y --no-install-recommends \
    curl ca-certificates git wget \
    && rm -rf /var/lib/apt/lists/*

# Install Go 1.25.12 (amd64-only, hardcoded) with multi-mirror fallback
# [INFO] Multi-mirror fallback strategy для надежной загрузки в любом регионе
RUN set -e; \
    GO_TARBALL="go${GO_VERSION}.linux-amd64.tar.gz"; \
    MIRRORS="https://go.dev/dl/${GO_TARBALL} https://golang.google.cn/dl/${GO_TARBALL} https://mirrors.ustc.edu.cn/golang/${GO_TARBALL} https://mirrors.aliyun.com/golang/${GO_TARBALL}"; \
    DOWNLOADED=false; \
    for mirror in $MIRRORS; do \
        echo ">>> Trying mirror: $mirror"; \
        if wget -q --timeout=30 "$mirror"; then \
            DOWNLOADED=true; \
            echo "    [OK] Downloaded from $mirror"; \
            break; \
        fi; \
    done; \
    if [ "$DOWNLOADED" = "false" ]; then \
        echo "[ERROR] All mirrors failed. Cannot download Go."; \
        exit 1; \
    fi; \
    tar -C /usr/local -xzf "$GO_TARBALL" && rm "$GO_TARBALL" && go version

# ============================================================================
# Stage 0.1: источник исходников — локальный src/umesh (BUILD_TYPE=local)
# или внешний инструмент umesh-prep (BUILD_TYPE=umeshprep, дефолт)
# ============================================================================
FROM go-toolchain AS src-provider-local
COPY src/umesh/ /local-src/

FROM go-toolchain AS src-provider-umeshprep
# Скачивание готового бинаря umesh-prep из GitHub Releases
# Версия задаётся в файле .umeshprep-version (single source of truth)
WORKDIR /umeshprep
ARG UMESHPREP_VERSION=v0.2.1
RUN wget -q "https://github.com/opscores/umesh-prep/releases/download/${UMESHPREP_VERSION}/umeshprep" \
    -O /umeshprep-bin && chmod +x /umeshprep-bin

# Идентификаторы проекта (явно задаём, не полагаемся на дефолты umesh-prep)
ARG TARGET_MODULE=github.com/opscores/umesh-node
ARG BECH32_PREFIX=umesh
ARG NODE_DIR=.umeshnode
ARG BINARY_NAME=umeshnode
ARG VERSION_NAME=umesh

# Настройка модулей (module toggling)
ARG ENABLE_IBC=true
ARG ENABLE_EVIDENCE=true
ARG ENABLE_UPGRADE=true
ARG ENABLE_FEAGRANT=true
ARG ENABLE_AUTHZ=true
ARG ENABLE_VESTING=true
ARG ENABLE_DEPRECATED=false

# Фича-флаги (opt-in, default false)
ARG ENABLE_BLOCKSTM=false
ARG ENABLE_IAVLX=false
ARG ENABLE_POA=false

# Вывод готового src/umesh в /local-src. SKIP_BUILD=1: компиляцию выполняет
# builder (в umeshprep нет clang/llvm для CGO сборки wasmvm).
RUN OUTPUT_DIR=/local-src UMESHPREP_IN_CONTAINER=1 SKIP_BUILD=1 \
    TARGET_MODULE=${TARGET_MODULE} \
    BECH32_PREFIX=${BECH32_PREFIX} \
    NODE_DIR=${NODE_DIR} \
    BINARY_NAME=${BINARY_NAME} \
    VERSION_NAME=${VERSION_NAME} \
    ENABLE_IBC=${ENABLE_IBC} \
    ENABLE_EVIDENCE=${ENABLE_EVIDENCE} \
    ENABLE_UPGRADE=${ENABLE_UPGRADE} \
    ENABLE_FEAGRANT=${ENABLE_FEAGRANT} \
    ENABLE_AUTHZ=${ENABLE_AUTHZ} \
    ENABLE_VESTING=${ENABLE_VESTING} \
    ENABLE_DEPRECATED=${ENABLE_DEPRECATED} \
    ENABLE_BLOCKSTM=${ENABLE_BLOCKSTM} \
    ENABLE_IAVLX=${ENABLE_IAVLX} \
    ENABLE_POA=${ENABLE_POA} \
    /umeshprep-bin

FROM src-provider-${BUILD_TYPE} AS src-builder

# ============================================================================
# Stage 1: Builder — компиляция бинарника umeshnode
# ============================================================================
FROM src-builder AS builder

ARG VERSION=dev
ARG COMMIT=unknown

# Установка build-зависимостей
# clang и llvm-dev ОБЯЗАТЕЛЬНЫ для CosmWasm v3.0.7 (CGO compilation)
# python3 больше не нужен: патчинг исходников выполняет внешний umesh-prep
RUN apt-get update --allow-releaseinfo-change && apt-get install -y --no-install-recommends \
    make build-essential \
    clang llvm-dev libclang-dev \
    && rm -rf /var/lib/apt/lists/* \
    && clang --version || (echo "ERROR: clang not installed" && exit 1)

WORKDIR /app

# Точка сборки финальных артефактов (бинарник + libwasmvm) для копирования в runtime
RUN mkdir -p /build

COPY --from=src-builder /local-src ./src/umesh/

WORKDIR /app/src/umesh

# Build binary with CGO_ENABLED=1 (required for CosmWasm wasmvm v3)
# [WARNING] CGO_ENABLED=1 ОБЯЗАТЕЛЬНО для CosmWasm v3.0.7 / WasmVM v3.0.7
# -buildvcs=false: suppress 'fatal: No names found' from Go's VCS detection
# (prepared source has no git tags; harmless but noisy)
RUN set -e; \
    export DEBIAN_FRONTEND=noninteractive; \
    if [ -f "Makefile" ] && grep -q "^build:" Makefile; then \
        CGO_ENABLED=1 LEDGER_ENABLED=false make build VERSION="${VERSION}" COMMIT="${COMMIT}"; \
        cp build/umeshnode /build/umeshnode; \
    else \
        CGO_ENABLED=1 go build -buildvcs=false -mod=readonly -ldflags '-s -w' -o /build/umeshnode ./cmd/umeshnode; \
    fi; \
    go clean -cache 2>/dev/null || true; \
    test -x /build/umeshnode || (echo "ERROR: umeshnode binary not built!" && exit 1)

# ============================================================================
# Copy libwasmvm runtime library (amd64-specific: x86_64)
# ============================================================================
# [WARNING] КРИТИЧНО: WasmVM v3.0.7 для amd64 использует libwasmvm.x86_64.so
# [INFO] Prefer arch-specific .so, fall back to any versioned libwasmvm*.so
# (glob должен пережить и вариант без .x86_64 суффикса).
RUN set -e; \
    WASMVM_SO=$({ find /go /root/go -name "libwasmvm*.x86_64.so" ! -name "*.a" 2>/dev/null; \
                  find /go /root/go -name "libwasmvm*.so" ! -name "*.a" 2>/dev/null; } | head -1); \
    if [ -z "$WASMVM_SO" ]; then \
        echo "ERROR: libwasmvm shared library not found"; \
        echo "       Searched for: libwasmvm*.x86_64.so / libwasmvm*.so (amd64)"; \
        echo "       Make sure CGO_ENABLED=1 during build"; \
        exit 1; \
    fi; \
    cp "$WASMVM_SO" "/build/$(basename $WASMVM_SO)"; \
    echo "Copied $(basename $WASMVM_SO) -> /build/$(basename $WASMVM_SO)"

# ============================================================================
# Verify binary linkage (проверка зависимостей)
# ============================================================================
RUN set -e; \
    echo ">>> Checking binary linkage..."; \
    ldd /build/umeshnode | grep -q "libwasmvm" || { echo "ERROR: libwasmvm not linked!" && exit 1; }; \
    if ldd /build/umeshnode | grep -q "not found"; then echo "ERROR: Unresolved dependencies!" && exit 1; fi; \
    /build/umeshnode version >/dev/null || { echo "ERROR: umeshnode binary cannot execute!" && exit 1; }

# ============================================================================
# Stage 2: Final — amd64 runtime с предустановленным dasel v3.11.2
# ============================================================================
FROM docker.io/library/ubuntu:26.04

LABEL org.opencontainers.image.title="Umesh Node (Validator + Sentry + RPC, amd64-only)"
LABEL org.opencontainers.image.description="Cosmos SDK v0.54 + CosmWasm v3.0.7 (Penta-Mode, amd64-only)"
LABEL org.opencontainers.image.source="https://github.com/opscores/umesh-node"

ENV DEBIAN_FRONTEND=noninteractive
ENV UMESH_HOME=/home/umesh/.umeshnode
ENV WASM_DIR=/home/umesh/.umeshnode/wasm
ENV TMPDIR=/tmp

ARG JQ_VERSION=1.8.2
ARG DASEL_VERSION=v3.11.2

# Install runtime dependencies + jq + dasel
# [WARNING] GitHub release CDN (objects.githubusercontent.com) периодически
# "черная дыра" из-за VPN/MTU (см. README "Горячая линия"): соединение
# устанавливается, но данные не идут. GNU wget без --timeout висит минуты,
# поэтому используем curl с таймаутами + фолбэк по зеркалам GitHub release
# (как в go-toolchain: multi-mirror fallback).
# [SECURITY] Каждый скачанный бинарь проверяется по официальному SHA-256.
# Прокси-зеркала могут служить MITM-каналом, поэтому несовпадение хеша
# считается фатальной ошибкой сборки — подменённый файл никогда не проходит.
# Хеши взяты с официальных страниц релизов jqlang/jq и TomWright/dasel.
# [INFO] Single RUN: update → install → download → verify → cleanup
RUN set -e; \
    export DEBIAN_FRONTEND=noninteractive; \
    JQ_SHA256="b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f"; \
    DASEL_SHA256="5006ee3a4239ab6a3edb1bf5c932874d814f7c276117ca677352697a4f547799"; \
    fetch() { \
        out="$1"; want="$2"; shift 2; \
        for url in "$@"; do \
            for base in "https://github.com" "https://gh-proxy.com/https://github.com" "https://ghfast.top/https://github.com" "https://ghproxy.net/https://github.com"; do \
                echo ">>> $out <- ${base}${url}"; \
                if curl -fsSL --retry 1 --retry-all-errors --retry-delay 2 \
                         --connect-timeout 8 --max-time 30 \
                         -o "$out" "${base}${url}"; then \
                    got=$(sha256sum "$out" | awk '{print $1}'); \
                    if [ "$got" = "$want" ]; then \
                        echo "    [OK] $out from ${base} (sha256 verified)"; \
                        return 0; \
                    fi; \
                    echo "    [FAIL] sha256 mismatch for $out from ${base}: expected $want, got $got"; \
                    rm -f "$out"; \
                fi; \
            done; \
        done; \
        echo "ERROR: all mirrors failed or failed verification for $out"; \
        return 1; \
    }; \
    apt-get update --allow-releaseinfo-change && apt-get install -y --no-install-recommends \
    ca-certificates curl libstdc++6 gosu \
    && gosu --version \
    && gosu nobody true \
    && fetch /usr/local/bin/jq "${JQ_SHA256}" "/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-linux-amd64" \
    && chmod +x /usr/local/bin/jq \
    && jq --version | grep -q "${JQ_VERSION}" \
    && fetch /usr/local/bin/dasel "${DASEL_SHA256}" "/TomWright/dasel/releases/download/${DASEL_VERSION}/dasel_linux_amd64" \
    && chmod +x /usr/local/bin/dasel \
    && dasel version \
    && echo "[OK] dasel ${DASEL_VERSION} installed successfully" \
    && rm -rf /var/lib/apt/lists/*

# Create umesh user AND all data directories here (critical for read_only: true)
# /etc/passwd is immutable at runtime, so user must exist in the image
# Directories created here work without volumes (ephemeral); compose mounts override them
RUN set -e; \
    # Remove any pre-existing umesh user/group for a deterministic rebuild.
    if id -u umesh >/dev/null 2>&1; then userdel umesh 2>/dev/null || true; fi; \
    if getent group umesh >/dev/null 2>&1; then groupdel umesh 2>/dev/null || true; fi; \
    # Free uid 1000 / gid 1000: the base image ships an 'ubuntu' user at uid 1000.
    # Without this remap, 'umesh' would end up with uid 1000 / gid 1001, which
    # breaks the '-u 1000:1000' offline runmounts used by umeshctl.
    if id -u 1000 >/dev/null 2>&1; then usermod -u 1001 "$(id -un 1000)" 2>/dev/null || true; fi; \
    if getent group 1000 >/dev/null 2>&1; then groupmod -g 1001 "$(getent group 1000 | cut -d: -f1)" 2>/dev/null || true; fi; \
    # Create umesh deterministically at uid 1000 / gid 1000 (matches host UID for bind mounts)
    groupadd -g 1000 umesh; \
    useradd -m -s /bin/bash -u 1000 -g 1000 umesh; \
    mkdir -p ${UMESH_HOME}/config ${UMESH_HOME}/data ${UMESH_HOME}/wasm ${UMESH_HOME}/keyring ${UMESH_HOME}/backups; \
    chown -R umesh:umesh /home/umesh

# ============================================================================
# Copy libwasmvm runtime (amd64: x86_64)
# ============================================================================
# [INFO] Use glob to handle versioned SONAME (e.g., libwasmvm.v3.0.7.x86_64.so)
COPY --from=builder /build/libwasmvm*.so /usr/local/lib/

RUN set -e; \
    WASMVM_REAL=$(ls /usr/local/lib/libwasmvm*.so 2>/dev/null | grep -v '\.a$' | head -1); \
    if [ -z "$WASMVM_REAL" ]; then \
        echo "ERROR: libwasmvm library not found after COPY"; \
        exit 1; \
    fi; \
    ln -sf "$WASMVM_REAL" /usr/local/lib/libwasmvm.so; \
    if [ "$(basename "$WASMVM_REAL")" != "libwasmvm.x86_64.so" ]; then \
        ln -sf "$WASMVM_REAL" /usr/local/lib/libwasmvm.x86_64.so; \
    fi; \
    ldconfig /usr/local/lib; \
    echo ">>> Linked: $WASMVM_REAL -> libwasmvm.so"

# ============================================================================
# Copy binary + smoke test
# ============================================================================
COPY --from=builder /build/umeshnode /usr/local/bin/umeshnode

# [WARNING] LD_LIBRARY_PATH критичен для runtime (libwasmvm может не найтись через ldconfig)
ENV LD_LIBRARY_PATH=/usr/local/lib

RUN chmod +x /usr/local/bin/umeshnode \
    && umeshnode version \
    && (umeshnode query wasm libwasmvm-version 2>/dev/null || echo "WARN: wasmvm query check unavailable in read-only mode")

# Verify dasel in final image
RUN dasel version && echo "[OK] dasel available in runtime"

# ============================================================================
# Entrypoint: Auto-init (umeshnode only) + privilege drop + PID 1 signal handling
# ============================================================================
# [INFO] On first run (no genesis.json), entrypoint runs umeshnode init + tuning
# via bash (no umeshctl in container). On subsequent runs skips init.
# ============================================================================
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start", "--home", "/home/umesh/.umeshnode"]

# ============================================================================
# Healthcheck via CometBFT RPC
# ============================================================================
# [INFO] Fallback healthcheck — docker-compose.yml overrides it per service.
#        Used only for plain `docker run` without compose.
# [INFO] Parameters mirror docker-compose.yml: interval 30s, timeout 15s,
#        retries 15, start-period 900s (state-sync may take ~15 min).
# ============================================================================
HEALTHCHECK --interval=30s --timeout=15s --start-period=900s --retries=15 \
    CMD curl -sf http://localhost:26657/health || exit 1

# Default Cosmos SDK ports (actual exposure controlled by docker-compose.yml)
# Validator: only 26656, 26657 (localhost), 26660 (localhost)
# Sentry/RPC: all ports (26656, 26657, 1317, 9090, 9091, 26658, 26660)
EXPOSE 26656 26657 26660 1317 9090 9091 26658

WORKDIR /home/umesh

# Graceful shutdown signal
STOPSIGNAL SIGTERM
