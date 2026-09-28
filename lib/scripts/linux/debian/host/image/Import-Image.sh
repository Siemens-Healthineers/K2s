#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/validation.sh"

tar_path=""
dir_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tar|--image-path)
      tar_path="$2"
      shift 2
      ;;
    -d|--dir|--image-dir)
      dir_path="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Import-Image.sh [-t <tar-path>] [-d <dir-path>]"
      exit 0
      ;;
    *)
      k2s_log ERROR "Unknown option: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$tar_path" && -z "$dir_path" ]]; then
  k2s_log ERROR "Either tar file path (-t) or directory path (-d) must be specified"
  exit 1
fi

import_single_tar() {
  local file="$1"
  k2s_log INFO "Importing container image from $file"
  if command -v buildah >/dev/null 2>&1; then
    if ! buildah pull "oci-archive:$file" 2>/dev/null; then
      k2s_run buildah pull "docker-archive:$file"
    fi
  elif command -v ctr >/dev/null 2>&1; then
    k2s_run ctr -n k8s.io images import "$file"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io load -i "$file"
  elif command -v podman >/dev/null 2>&1; then
    k2s_run podman load -i "$file"
  elif command -v docker >/dev/null 2>&1; then
    k2s_run docker load -i "$file"
  else
    k2s_log ERROR "No container tool found to import image. Please install buildah or containerd (ctr)."
    exit 127
  fi
}

if [[ -n "$tar_path" ]]; then
  k2s_require_file "$tar_path" || exit 1
  import_single_tar "$tar_path"
fi

if [[ -n "$dir_path" ]]; then
  k2s_require_directory "$dir_path" || exit 1
  k2s_log INFO "Importing container images from directory $dir_path"
  shopt -s nullglob
  tar_files=("$dir_path"/*.tar)
  shopt -u nullglob
  if [[ ${#tar_files[@]} -eq 0 ]]; then
    k2s_log WARN "No .tar files found in $dir_path"
  else
    for file in "${tar_files[@]}"; do
      import_single_tar "$file"
    done
  fi
fi
