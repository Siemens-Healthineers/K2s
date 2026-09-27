#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export K2S_INSTALL_DIR="${K2S_INSTALL_DIR:-$(cd "$script_dir/../../../../../.." && pwd)}"
export K2S_LOG_FILE="${K2S_LOG_FILE:-/var/log/k2s.log}"

source "$K2S_INSTALL_DIR/lib/modules/linux/common/logging.sh"
source "$K2S_INSTALL_DIR/lib/modules/linux/common/command.sh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      echo "Usage: Clean-Images.sh"
      exit 0
      ;;
    *)
      shift
      ;;
  esac
done

k2s_log INFO "Cleaning non-Kubernetes container images using crictl"

images_json="$(crictl images -o json 2>/dev/null || true)"
if [[ -z "$images_json" ]]; then
  k2s_log INFO "No container images found"
  exit 0
fi

# Filter out Kubernetes infrastructure images (registry.k8s.io, k8s.gcr.io, flannel, calico, coreos)
non_k8s_ids=$(echo "$images_json" | jq -r '
  def is_k8s:
    ([.repoTags[]? | select(startswith("registry.k8s.io/") or startswith("k8s.gcr.io/") or startswith("docker.io/flannel") or startswith("docker.io/calico") or startswith("quay.io/coreos"))] | length > 0) or
    ([.repoDigests[]? | select(startswith("registry.k8s.io/") or startswith("k8s.gcr.io/") or startswith("docker.io/flannel") or startswith("docker.io/calico") or startswith("quay.io/coreos"))] | length > 0);
  .images[]? | select(is_k8s | not) | .id
' 2>/dev/null || true)

if [[ -z "$non_k8s_ids" ]]; then
  k2s_log INFO "No non-Kubernetes container images to clean"
  exit 0
fi

failed=0
while IFS= read -r image_id; do
  [[ -n "$image_id" ]] || continue
  k2s_log INFO "Removing non-Kubernetes container image $image_id"
  if ! crictl rmi "$image_id"; then
    k2s_log WARN "Could not remove image $image_id"
    failed=1
  fi
done <<< "$non_k8s_ids"

if [[ $failed -ne 0 ]]; then
  k2s_log WARN "Some container images could not be removed"
fi
