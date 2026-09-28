#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

dir="."
dockerfile=""
name=""
tag=""
push=false
build_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--dir|--input-folder)
      dir="$2"
      shift 2
      ;;
    -f|--file|--dockerfile)
      dockerfile="$2"
      shift 2
      ;;
    -n|--name|--image-name)
      name="$2"
      shift 2
      ;;
    -t|--tag|--image-tag)
      tag="$2"
      shift 2
      ;;
    -p|--push)
      push=true
      shift
      ;;
    --build-arg)
      build_args+=("--build-arg" "$2")
      shift 2
      ;;
    --build-arg=*)
      build_args+=("--build-arg" "${1#*=}")
      shift
      ;;
    -h|--help)
      echo "Usage: Build-Image.sh [-d <dir>] [-f <dockerfile>] [-n <name>] [-t <tag>] [--push] [--build-arg <k=v>...]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

k2s_require_directory "$dir" || exit 1

full_image=""
if [[ -n "$name" && -n "$tag" ]]; then
  full_image="${name}:${tag}"
elif [[ -n "$name" ]]; then
  full_image="${name}"
elif [[ -n "$tag" ]]; then
  full_image="${tag}"
fi

builder=""
if command -v buildah >/dev/null 2>&1; then
  builder="buildah"
elif command -v nerdctl >/dev/null 2>&1; then
  builder="nerdctl"
elif command -v podman >/dev/null 2>&1; then
  builder="podman"
elif command -v docker >/dev/null 2>&1; then
  builder="docker"
else
  k2s_log ERROR "No container image builder found. Please install buildah (apt-get install -y buildah) or nerdctl."
  exit 127
fi

build_cmd=("$builder")
if [[ "$builder" == "buildah" ]]; then
  build_cmd+=("bud")
else
  build_cmd+=("build")
fi

if [[ -n "$dockerfile" ]]; then
  build_cmd+=("-f" "$dockerfile")
fi
if [[ -n "$full_image" ]]; then
  build_cmd+=("-t" "$full_image")
fi
if [[ ${#build_args[@]} -gt 0 ]]; then
  build_cmd+=("${build_args[@]}")
fi
build_cmd+=("$dir")

k2s_log INFO "Building container image with $builder"
k2s_run "${build_cmd[@]}"

if [[ "$push" == true ]]; then
  if [[ -z "$full_image" ]]; then
    k2s_log ERROR "Cannot push image: image name not specified"
    exit 1
  fi
  k2s_log INFO "Pushing container image $full_image with $builder"
  k2s_run "$builder" push "$full_image"
fi
