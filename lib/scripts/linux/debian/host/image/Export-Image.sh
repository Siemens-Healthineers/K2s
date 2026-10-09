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

# Ensure image_name and tag are resolved so the archive stores the reference name
if [[ -z "$image_name" && -n "$ref" ]]; then
  if command -v buildah >/dev/null 2>&1; then
    resolved_name="$(buildah images --json "$ref" 2>/dev/null | jq -r '.[0].names[]? // empty' 2>/dev/null | grep -v '<none>' | head -n 1 || true)"
    if [[ -n "$resolved_name" ]]; then
      image_name="$resolved_name"
    fi
  fi
  if [[ -z "$image_name" ]] && command -v crictl >/dev/null 2>&1; then
    resolved_name="$(crictl inspecti "$ref" 2>/dev/null | jq -r '.status.repoTags[]? // empty' 2>/dev/null | grep -v '<none>' | head -n 1 || true)"
    if [[ -n "$resolved_name" ]]; then
      image_name="$resolved_name"
    fi
  fi
fi

if [[ -z "$image_name" ]]; then
  image_name="${ref}:latest"
fi

if [[ "$image_name" != *":"* ]]; then
  image_name="${image_name}:latest"
fi

if [[ "$docker_archive" == true ]]; then
  k2s_log INFO "Exporting image $ref as Docker archive to $tar_path ($image_name)"
  if command -v buildah >/dev/null 2>&1; then
    archive_spec="docker-archive:$tar_path:$image_name"
    if [[ "$ref" != localhost/* ]] && ! buildah inspect "$ref" >/dev/null 2>&1 && buildah inspect "localhost/$ref" >/dev/null 2>&1; then
      ref="localhost/$ref"
    fi
    if ! k2s_run buildah push "$ref" "$archive_spec"; then
      if [[ "$ref" != localhost/* ]]; then
        k2s_run buildah push "localhost/$ref" "$archive_spec"
      else
        exit 1
      fi
    fi
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io save -o "$tar_path" "$ref"
  else
    k2s_log ERROR "No container tool found to export image as Docker archive. Please install buildah or nerdctl."
    exit 127
  fi
else
  k2s_log INFO "Exporting image $ref as OCI archive to $tar_path ($image_name)"
  if command -v buildah >/dev/null 2>&1; then
    archive_spec="oci-archive:$tar_path:$image_name"
    if [[ "$ref" != localhost/* ]] && ! buildah inspect "$ref" >/dev/null 2>&1 && buildah inspect "localhost/$ref" >/dev/null 2>&1; then
      ref="localhost/$ref"
    fi
    if ! k2s_run buildah push "$ref" "$archive_spec"; then
      if [[ "$ref" != localhost/* ]]; then
        k2s_run buildah push "localhost/$ref" "$archive_spec"
      else
        exit 1
      fi
    fi
  elif command -v ctr >/dev/null 2>&1; then
    export_ref="$ref"
    if [[ -n "$image_name" ]]; then
      export_ref="$image_name"
    fi
    k2s_run ctr -n k8s.io images export "$tar_path" "$export_ref"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io save -o "$tar_path" "$ref"
  else
    k2s_log ERROR "No container tool found to export image as OCI archive. Please install buildah or containerd (ctr)."
    exit 127
  fi
fi
