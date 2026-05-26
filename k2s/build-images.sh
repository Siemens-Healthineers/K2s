#!/bin/bash
set -e

# Build a2a-proxy image
echo "Building a2a-proxy image..."
container=$(buildah from scratch)
buildah copy $container /tmp/a2a-proxy /a2a-proxy
buildah config --entrypoint '["/a2a-proxy"]' $container
buildah config --user 65534:65534 $container
buildah commit $container shsk2s.azurecr.io/a2a-proxy:latest
buildah rm $container

# Build mcp-preprocessor image
echo "Building mcp-preprocessor image..."
container=$(buildah from scratch)
buildah copy $container /tmp/mcp-preprocessor /mcp-preprocessor
buildah config --entrypoint '["/mcp-preprocessor"]' $container
buildah config --user 65534:65534 $container
buildah commit $container shsk2s.azurecr.io/mcp-preprocessor:latest
buildah rm $container

# Copy images to CRI-O storage
echo "Copying images to CRI-O storage..."
buildah push shsk2s.azurecr.io/a2a-proxy:latest containers-storage:shsk2s.azurecr.io/a2a-proxy:latest
buildah push shsk2s.azurecr.io/mcp-preprocessor:latest containers-storage:shsk2s.azurecr.io/mcp-preprocessor:latest

echo "Verifying images available to crictl..."
crictl images | grep -E "a2a-proxy|mcp-preprocessor"

echo "DONE - Images built and available to CRI-O"

