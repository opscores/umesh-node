#!/usr/bin/env bash
# ============================================================================
# entrypoint.sh — start umeshnode with privilege drop
# ============================================================================
# Does NOT perform node initialization. Run umeshctl setup init on the host first:
#   umeshctl setup init --role <genesis|validator|sentry|rpc> \
#     --config config/node-<role>.yaml \
#     --keyring-password-file ~/.umesh/keyring-pass
#
# Then start the container:
#   docker compose --env-file .env.<role> --profile <role> up -d
#
# Container ensures directories exist, drops privileges,
# and execs umeshnode as PID 1. Tuning is applied on the host
# by umeshctl during `setup init` / `setup tune`.
# ============================================================================
set -euo pipefail

# =============================================================================
# Root init (runs as root, before privilege drop)
# =============================================================================
if [ "$(id -u)" -eq 0 ]; then
    # Fix ownership of the bind-mounted data directories (Docker may auto-create
    # missing bind sources as root:root). Only the mounted .umeshnode subdirs are
    # touched — the rest of /home/umesh lives on the read-only rootfs (compose
    # uses read_only: true) and already has the right owner from the image.
    # Non-fatal: NFS with root_squash or read-only mounts make chown fail, but
    # the failure must be visible — otherwise umeshnode dies later with a cryptic
    # "permission denied" and no clue why.
    if ! chown -R umesh:umesh /home/umesh/.umeshnode/config /home/umesh/.umeshnode/data \
        /home/umesh/.umeshnode/wasm /home/umesh/.umeshnode/keyring /home/umesh/.umeshnode/backups \
        2>/dev/null; then
        echo "[WARN] chown /home/umesh/.umeshnode/* failed (NFS/read-only mount?) — umeshnode may be unable to write" >&2
    fi
    # Privilege drop
    exec gosu umesh "$0" "$@"
fi

# =============================================================================
# Subcommands passthrough (debug, admin)
# =============================================================================
case "${1:-}" in
    sh|bash|dash|dasel|jq|curl|python3|unzip|sleep|true|false|env)
        exec "$@"
        ;;
esac

# umeshnode passthrough
if [ "${1:-}" = "umeshnode" ]; then
    shift
    exec /usr/local/bin/umeshnode "$@"
fi

# umeshnode subcommands passthrough
case "${1:-}" in
    init|keys|genesis|query|tx|comet|version|status|export|rollback|prune|testnet|tendermint|debug|config|confix)
        exec /usr/local/bin/umeshnode "$@"
        ;;
esac

# Default: start umeshnode (PID 1)
echo "[entrypoint] Starting umeshnode with args: $*"
exec /usr/local/bin/umeshnode "$@"
