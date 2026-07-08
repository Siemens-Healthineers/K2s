#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# Native Linux build for the K2s Go executables -- no PowerShell required.
#
# Mirrors the Linux build performed by smallsetup/common/BuildGoExe.ps1
# (GOOS=linux, GOARCH=amd64, GOEXPERIMENT=boringcrypto, matching ldflags and
# gcflags, and the same version metadata injected into internal/version).
#
# Usage:
#   ./build.sh                 build all Linux executables
#   ./build.sh --proxy URL     route Go module downloads through a proxy
#   ./build.sh -h | --help     show usage

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: ./build.sh [--proxy URL]

Builds the Linux-targeted K2s Go executables natively (no PowerShell):
  k2s                 -> repository root
  cloudinitisobuilder -> bin/
  httpproxy           -> bin/
  yaml2json           -> bin/

Options:
  --proxy URL   Set HTTP_PROXY/HTTPS_PROXY for Go module downloads.
  -h, --help    Show this help.
EOF
}

PROXY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --proxy)
            if [[ $# -lt 2 ]]; then
                echo "error: --proxy requires a URL argument" >&2
                exit 2
            fi
            PROXY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            usage >&2
            exit 2
            ;;
    esac
done

# Repository root = directory containing this script.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

if ! command -v go >/dev/null 2>&1; then
    echo "error: 'go' not found on PATH. Install Go (see go.mod for the required version)." >&2
    exit 1
fi

# boringcrypto for FIPS compliance (matches BuildGoExe.ps1).
export GOEXPERIMENT=boringcrypto
export GOOS=linux
export GOARCH=amd64

if [[ -n "$PROXY" ]]; then
    echo "Using proxy: $PROXY"
    export HTTP_PROXY="$PROXY"
    export HTTPS_PROXY="$PROXY"
fi

# VERSION
VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION")"
echo "VERSION: $VERSION"

# BUILD DATE
BUILD_DATE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
echo "BUILD_DATE: $BUILD_DATE"

# GIT COMMIT
GIT_COMMIT="$(git rev-parse HEAD)"
echo "GIT_COMMIT: $GIT_COMMIT"

# GIT TREE STATE AND TAG
GIT_TAG=""
GIT_TREE_STATE="clean"
if [[ -n "$(git status --porcelain)" ]]; then
    GIT_TREE_STATE="dirty"
else
    # Clean tree: check for an exact tag to declare an official release.
    if GIT_TAG="$(git describe --exact-match --tags HEAD 2>/dev/null)"; then
        echo "GIT_TAG: $GIT_TAG"
    else
        GIT_TAG=""
        echo "No tag found for the git commit"
    fi
fi
echo "GIT_TREE_STATE: $GIT_TREE_STATE"

VERSION_PKG="github.com/siemens-healthineers/k2s/internal/version"
LDFLAGS="-s -w \
-X ${VERSION_PKG}.version=${VERSION} \
-X ${VERSION_PKG}.buildDate=${BUILD_DATE} \
-X ${VERSION_PKG}.gitCommit=${GIT_COMMIT} \
-X ${VERSION_PKG}.gitTag=${GIT_TAG} \
-X ${VERSION_PKG}.gitTreeState=${GIT_TREE_STATE}"

BIN_DIR="$REPO_ROOT/bin"
mkdir -p "$BIN_DIR"

# Linux-targeted executables: command package -> output file.
# Mirrors BuildGoExe.ps1's mapping minus the Windows-only apps.
#   app|output_path
BUILD_TARGETS=(
    "k2s|$REPO_ROOT/k2s"
    "cloudinitisobuilder|$BIN_DIR/cloudinitisobuilder"
    "httpproxy|$BIN_DIR/httpproxy"
    "yaml2json|$BIN_DIR/yaml2json"
)

# The Go module (go.mod) lives under k2s/, so build from there and reference
# each command by its module-relative package path (./cmd/<app>).
cd "$REPO_ROOT/k2s"

for target in "${BUILD_TARGETS[@]}"; do
    app="${target%%|*}"
    out_path="${target#*|}"
    echo "Building GO executable: $app -> $out_path ..."
    go build \
        -ldflags "$LDFLAGS" \
        -gcflags=all="-l -B" \
        -o "$out_path" \
        "./cmd/${app}"
    echo "Built: \"$out_path\""
done

echo '---------------------------------------------------------------'
echo ' Build finished.'
echo '---------------------------------------------------------------'
