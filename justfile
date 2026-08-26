# ============================================================================
# justfile — Umesh Node
# ============================================================================

_default:
    @just --list

# ----------------------------------------------------------------------------
# Build
# ----------------------------------------------------------------------------

# Build umeshctl CLI binary (auto-detect: local Go or Docker)
build-cli:
    @bash scripts/build-cli.sh

# Generate src/umesh via external umesh-prep tool (clean + regenerate)
prepare:
	@echo ">>> Generating src/umesh via umesh-prep..."
	@rm -rf src/umesh
	@mkdir -p bin
	@if [ ! -f bin/umeshprep ]; then \
		UMESHPREP_VERSION=$(cat .umeshprep-version 2>/dev/null || echo v0.2.1); \
		echo ">>> Downloading umesh-prep $UMESHPREP_VERSION"; \
		wget -q "https://github.com/opscores/umesh-prep/releases/download/$UMESHPREP_VERSION/umeshprep" \
		-O bin/umeshprep && chmod +x bin/umeshprep; \
	fi
	@OUTPUT_DIR=src/umesh SKIP_BUILD=1 \
	TARGET_MODULE=github.com/opscores/umesh-node \
	BECH32_PREFIX=umesh \
	NODE_DIR=.umeshnode \
	BINARY_NAME=umeshnode \
	VERSION_NAME=umesh \
	bin/umeshprep

# Build Docker image with local src/umesh/ (requires `just prepare` first)
# Temporarily removes /src/ from .dockerignore to include local sources in context
build-local: prepare
	@cp .dockerignore .dockerignore.bak
	@sed -i '/^\/src\/$/d' .dockerignore
	@docker build --pull \
		--build-arg BUILD_TYPE="local" \
		--build-arg VERSION="dev" \
		--build-arg COMMIT="$(git rev-parse --short HEAD)" \
		-t "umesh-node:latest" -f Dockerfile .
	@mv .dockerignore.bak .dockerignore

# Build Docker image with umesh-prep (generates sources inside container)
# Feature flags via env vars: ENABLE_IBC, ENABLE_EVIDENCE, ENABLE_UPGRADE,
# ENABLE_FEAGRANT, ENABLE_AUTHZ, ENABLE_VESTING, ENABLE_DEPRECATED,
# ENABLE_BLOCKSTM, ENABLE_IAVLX, ENABLE_POA
# Example: ENABLE_IBC=false just build-umeshprep
build-umeshprep:
	@docker build --pull \
		--build-arg BUILD_TYPE="umeshprep" \
		--build-arg UMESHPREP_VERSION="$(cat .umeshprep-version 2>/dev/null || echo v0.2.1)" \
		--build-arg VERSION="dev" \
		--build-arg COMMIT="$(git rev-parse --short HEAD)" \
		--build-arg TARGET_MODULE="github.com/opscores/umesh-node" \
		--build-arg BECH32_PREFIX="umesh" \
		--build-arg NODE_DIR=".umeshnode" \
		--build-arg BINARY_NAME="umeshnode" \
		--build-arg VERSION_NAME="umesh" \
		--build-arg ENABLE_IBC="${ENABLE_IBC:-true}" \
		--build-arg ENABLE_EVIDENCE="${ENABLE_EVIDENCE:-true}" \
		--build-arg ENABLE_UPGRADE="${ENABLE_UPGRADE:-true}" \
		--build-arg ENABLE_FEAGRANT="${ENABLE_FEAGRANT:-true}" \
		--build-arg ENABLE_AUTHZ="${ENABLE_AUTHZ:-true}" \
		--build-arg ENABLE_VESTING="${ENABLE_VESTING:-true}" \
		--build-arg ENABLE_DEPRECATED="${ENABLE_DEPRECATED:-false}" \
		--build-arg ENABLE_BLOCKSTM="${ENABLE_BLOCKSTM:-false}" \
		--build-arg ENABLE_IAVLX="${ENABLE_IAVLX:-false}" \
		--build-arg ENABLE_POA="${ENABLE_POA:-false}" \
		-t "umesh-node:latest" -f Dockerfile .

# Build CLI + Docker image
build: build-cli build-umeshprep

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------

# Resolve the keyring password flag for non-interactive use.
# Set UMESH_KEYRING_PASS_FILE to a file containing the password, or
# leave unset to use interactive stdin prompt.
keyring-pass-flag:
    @if [ -n "$UMESH_KEYRING_PASS_FILE" ]; then \
        printf '%s' "--keyring-password-file $UMESH_KEYRING_PASS_FILE"; \
    else \
        printf '%s' "--keyring-password-stdin"; \
    fi

# Build and run validator in genesis phase (create new network, Block 0)
run-validator-genesis: build
    @docker network inspect umesh >/dev/null 2>&1 || docker network create umesh
    @[ -f config/node-genesis.yaml ] || { echo "Error: config/node-genesis.yaml not found. Copy from config/node-config-genesis.yaml.example"; exit 1; }
    @./tools/umeshctl/umeshctl setup init --role genesis --config config/node-genesis.yaml $(just keyring-pass-flag)
    @docker compose --env-file .env.genesis --profile validator up -d

# Build and run validator (join existing network)
run-validator: build
    @docker network inspect umesh >/dev/null 2>&1 || docker network create umesh
    @[ -f config/node-validator.yaml ] || { echo "Error: config/node-validator.yaml not found. Copy from config/node-config-validator.yaml.example"; exit 1; }
    @./tools/umeshctl/umeshctl setup init --role validator --config config/node-validator.yaml $(just keyring-pass-flag)
    @docker compose --env-file .env.validator --profile validator up -d

# Build and run sentry (public peer-facing relay)
run-sentry: build
    @docker network inspect umesh >/dev/null 2>&1 || docker network create umesh
    @[ -f config/node-sentry.yaml ] || { echo "Error: config/node-sentry.yaml not found. Copy from config/node-config-sentry.yaml.example"; exit 1; }
    @./tools/umeshctl/umeshctl setup init --role sentry --config config/node-sentry.yaml $(just keyring-pass-flag)
    @docker compose --env-file .env.sentry --profile sentry up -d

# Build and run rpc (public RPC node)
run-rpc: build
    @docker network inspect umesh >/dev/null 2>&1 || docker network create umesh
    @[ -f config/node-rpc.yaml ] || { echo "Error: config/node-rpc.yaml not found. Copy from config/node-config-rpc.yaml.example"; exit 1; }
    @./tools/umeshctl/umeshctl setup init --role rpc --config config/node-rpc.yaml $(just keyring-pass-flag)
    @docker compose --env-file .env.rpc --profile rpc up -d

# ----------------------------------------------------------------------------
# Cleanup
# ----------------------------------------------------------------------------

# Delete ALL data, keys, genesis, backups (destructive!)
clean:
    @echo "[WARNING] This will DELETE ALL DATA"
    @docker compose --profile validator down 2>/dev/null || true
    @docker compose --profile sentry down 2>/dev/null || true
    @docker compose --profile rpc down 2>/dev/null || true
    @docker network rm umesh 2>/dev/null || true
    @rm -rf ./data-validator ./data-sentry ./data-rpc ./backups ./src/umesh ./tools/umeshctl/umeshctl
