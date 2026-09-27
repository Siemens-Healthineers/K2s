#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

image_id=""
image_name=""
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--id|--image-id)
      image_id="$2"
      shift 2
      ;;
    -n|--name|--image-name)
      image_name="$2"
      shift 2
      ;;
    -f|--force)
      force=true
      shift
      ;;
    -h|--help)
      echo "Usage: Remove-Image.sh [-i <id>] [-n <name>] [--force]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

ref=""
if [[ -n "$image_id" ]]; then
  ref="$image_id"
elif [[ -n "$image_name" ]]; then
  ref="$image_name"
else
  k2s_log ERROR "Either image ID (-i) or image name (-n) must be specified"
  exit 1
fi

rmi_cmd=("crictl" "rmi")
if [[ "$force" == true ]]; then
  rmi_cmd+=("--force")
fi
rmi_cmd+=("$ref")

k2s_log INFO "Removing container image $ref"
k2s_run "${rmi_cmd[@]}"
