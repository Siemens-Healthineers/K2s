#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

image_name=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name|--image-name)
      image_name="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Push-Image.sh -n <image-name>"
      exit 0
      ;;
    -*)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
    *)
      if [[ -z "$image_name" ]]; then
        image_name="$1"
        shift
      else
        k2s_log ERROR "Unexpected argument: $1"
        exit 1
      fi
      ;;
  esac
done

if [[ -z "$image_name" ]]; then
  k2s_log ERROR "Image name (-n) must be specified"
  exit 1
fi

k2s_log INFO "Pushing container image $image_name"
if command -v buildah >/dev/null 2>&1; then
  k2s_run buildah push "$image_name"
elif command -v nerdctl >/dev/null 2>&1; then
  k2s_run nerdctl push "$image_name"
elif command -v podman >/dev/null 2>&1; then
  k2s_run podman push "$image_name"
elif command -v docker >/dev/null 2>&1; then
  k2s_run docker push "$image_name"
else
  k2s_log ERROR "No container tool found to push image. Please install buildah (apt-get install -y buildah) or nerdctl."
  exit 127
fi
