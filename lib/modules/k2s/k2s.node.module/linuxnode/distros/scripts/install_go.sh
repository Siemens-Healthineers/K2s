#!/bin/bash

# SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
#
# SPDX-License-Identifier: MIT

# Set the Go version
GO_VERSION="1.21.4"

# Proxy
PROXY="http://172.19.1.1:8181"

# Set the installation directory
INSTALL_DIR="/usr/local"

# Download and extract the Go binary
sudo curl -LO https://golang.org/dl/go$GO_VERSION.linux-amd64.tar.gz --proxy $PROXY
sudo tar -C $INSTALL_DIR -xzf go$GO_VERSION.linux-amd64.tar.gz

# Add Go binary to the system PATH
echo "export PATH=\$PATH:$INSTALL_DIR/go/bin" >> .profile
echo "export GOPATH=\$HOME/go" >> .profile

# Apply the changes to the current session
source .profile

# Clean up downloaded files
rm go$GO_VERSION.linux-amd64.tar.gz

# Display Go version
go version
