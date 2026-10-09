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

image_name=""

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
    -n|--name|--image-name)
      image_name="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: Import-Image.sh [-t <tar-path>] [-d <dir-path>] [-n <image-name>]"
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
  local explicit_name="${2:-$image_name}"
  k2s_log INFO "Importing container image from $file"
  if command -v buildah >/dev/null 2>&1; then
    local pull_out=""
    if pull_out="$(buildah pull "oci-archive:$file" 2>&1)"; then
      k2s_log INFO "Successfully imported OCI archive: $file"
    elif pull_out="$(buildah pull "docker-archive:$file" 2>&1)"; then
      k2s_log INFO "Successfully imported Docker archive: $file"
    else
      k2s_log ERROR "Failed to import image from $file: $pull_out"
      return 1
    fi

    local imported_id=""
    imported_id="$(echo "$pull_out" | grep -oE '[0-9a-f]{12,64}' | tail -n 1 || true)"
    if [[ -z "$imported_id" ]]; then
      imported_id="$(echo "$pull_out" | tail -n 1 | tr -d '\r\n' || true)"
    fi

    # Check if the imported image has any non-<none> names in buildah
    local current_names=""
    if [[ -n "$imported_id" ]]; then
      current_names="$(buildah images --json "$imported_id" 2>/dev/null | jq -r '.[0].names[]? // empty' 2>/dev/null | grep -v '<none>' || true)"
    fi

    # If the image was imported without tags (names appears as <none>), resolve and apply the tag
    if [[ -z "$current_names" && -n "$imported_id" ]]; then
      local tag_to_apply="$explicit_name"

      if [[ -z "$tag_to_apply" ]]; then
        # 1. Try reading OCI archive index.json annotation
        tag_to_apply="$(tar -xOf "$file" index.json 2>/dev/null | jq -r '.manifests[0].annotations["org.opencontainers.image.ref.name"] // empty' 2>/dev/null || true)"
      fi

      if [[ -z "$tag_to_apply" || "$tag_to_apply" == "null" ]]; then
        # 2. Try reading Docker manifest.json RepoTags
        tag_to_apply="$(tar -xOf "$file" manifest.json 2>/dev/null | jq -r '.[0].RepoTags[0] // empty' 2>/dev/null || true)"
      fi

      if [[ -z "$tag_to_apply" || "$tag_to_apply" == "null" ]]; then
        # 3. Derive from archive filename if it is not a hexadecimal hash
        local base_name="$(basename "$file" .tar)"
        base_name="${base_name%_linux}"
        if [[ ! "$base_name" =~ ^[0-9a-f]{12,64}$ ]]; then
          if [[ "$base_name" == *":"* ]]; then
            tag_to_apply="$base_name"
          else
            tag_to_apply="${base_name}:latest"
          fi
        fi
      fi

      if [[ -n "$tag_to_apply" && "$tag_to_apply" != "<none>" && "$tag_to_apply" != "null" ]]; then
        k2s_log INFO "Tagging imported image $imported_id as $tag_to_apply"
        buildah tag "$imported_id" "$tag_to_apply" || true
      fi
    fi
  elif command -v ctr >/dev/null 2>&1; then
    k2s_run ctr -n k8s.io images import "$file"
  elif command -v nerdctl >/dev/null 2>&1; then
    k2s_run nerdctl -n k8s.io load -i "$file"
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
