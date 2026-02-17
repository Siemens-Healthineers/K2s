# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Multi-stage build for K2s Addon Controller - Linux
FROM golang:1.25 AS builder

WORKDIR /workspace

# Build-time variables for version injection
ARG VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=unknown

# Copy source from build context root (expects pkg/controller as build context)
COPY . ./

# Download dependencies with network timeout and retries
RUN go env -w GOPROXY=https://proxy.golang.org,direct && \
    go mod download

# Build the controller for Linux with version info
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o addon-controller \
    -ldflags="-s -w \
      -X main.version=${VERSION} \
      -X main.gitCommit=${GIT_COMMIT} \
      -X main.buildDate=${BUILD_DATE}" \
    ./cmd/main.go


# Runtime image - slim Debian for nsenter (required to exec buildah/dpkg on host via hostPID)
# Distroless cannot be used because nsenter must exist inside the container to enter host namespaces.
FROM debian:12-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends util-linux && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /

# Copy controller binary
COPY --from=builder /workspace/addon-controller .

# Expose metrics and health probe ports
EXPOSE 8080 8081

# Run as root — required for nsenter --target 1 (entering host PID namespace)
USER root

ENTRYPOINT ["/addon-controller"]
