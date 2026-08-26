#!/bin/bash
set -euo pipefail

# Auto-detect Go 1.25+ on host, fallback to Docker.
# umeshctl lives in a separate repo (umesh-cli) and is cloned into tools/umeshctl/.
REPO_URL="git@github.com:opscores/umesh-cli.git"
CLONE_BRANCH="dev"
CLI_DIR="$(cd "$(dirname "$0")/.." && pwd)/tools/umeshctl"

# Clone the CLI source if it is not present yet (local dev copy, gitignored).
if [ ! -d "$CLI_DIR/.git" ]; then
    echo "[build] cloning umeshctl source into tools/umeshctl/"
    mkdir -p "$CLI_DIR"
    git clone --depth 1 --branch "$CLONE_BRANCH" "$REPO_URL" "$CLI_DIR"
fi

GO_VERSION=$(go version 2>/dev/null | sed -n 's/.*go1\.\([0-9]*\).*/\1/p')

LDFLAGS="-X github.com/umesh-network/umeshctl/cmd.Version=dev"
LDFLAGS="$LDFLAGS -X github.com/umesh-network/umeshctl/cmd.GitCommit=$(git -C "$CLI_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)"
LDFLAGS="$LDFLAGS -X github.com/umesh-network/umeshctl/cmd.BuildDate=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [ -n "$GO_VERSION" ] && [ "$GO_VERSION" -ge 25 ]; then
    echo "[build] local Go 1.${GO_VERSION}"
    cd "$CLI_DIR" && go build -ldflags "$LDFLAGS" -o umeshctl .
else
    echo "[build] Docker golang:1.25"
    docker run --rm -v "$(dirname "$CLI_DIR")":/app -w /app/umeshctl golang:1.25 \
        go build -buildvcs=false -ldflags "$LDFLAGS" -o umeshctl .
fi
