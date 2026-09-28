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
tar_path=""
docker_archive=false

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
    -t|--tar|--output|-o)
      tar_path="$2"
      shift 2
      ;;
    --docker-archive)
      docker_archive=true
      shift
      ;;
    -h|--help)
      echo "Usage: Export-Image.sh [-i <id>] [-n <name>] -t <tar-path> [--docker-archive]"
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

if [[ -z "$tar_path" ]]; then
  k2s_log ERROR "Export target tar path (-t) must be specified"
  exit 1
fi

mkdir -p "$(dirname "$tar_path")"

if [[ "$docker_archive" == true ]]; then
  k2s_log INFO "Exporting image $ref as Docker archive to $tar_path"
  if command -v buildah >/dev/null 2>&1; then
    archive_spec="docker-archive:$tar_path"
    if [[ -n "$image_name" ]]; then
      archive_spec="docker-archive:$tar_path:$image_name"
    fi
    k2s_run buildah push "$ref" "$archive_spec"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io save -o "$tar_path" "$ref"
  elif command -v podman >/dev/null 2>&1; then
    k2s_run podman save -o "$tar_path" "$ref"
  elif command -v docker >/dev/null 2>&1; then
    k2s_run docker save -o "$tar_path" "$ref"
  else
    k2s_log ERROR "No container tool found to export image as Docker archive. Please install buildah, nerdctl, podman, or docker."
    exit 127
  fi
else
  k2s_log INFO "Exporting image $ref as OCI archive to $tar_path"
  if command -v buildah >/dev/null 2>&1; then
    archive_spec="oci-archive:$tar_path"
    if [[ -n "$image_name" ]]; then
      archive_spec="oci-archive:$tar_path:$image_name"
    fi
    k2s_run buildah push "$ref" "$archive_spec"
  elif command -v ctr >/dev/null 2>&1; then
    k2s_run ctr -n k8s.io images export "$tar_path" "$ref"
  elif command -v podman >/dev/null 2>&1; then
    archive_spec="oci-archive:$tar_path"
    if [[ -n "$image_name" ]]; then
      archive_spec="oci-archive:$tar_path:$image_name"
    fi
    k2s_run podman push "$ref" "$archive_spec"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io save -o "$tar_path" "$ref"
  else
    k2s_log ERROR "No container tool found to export image as OCI archive. Please install buildah or containerd (ctr)."
    exit 127
  fi
fi
