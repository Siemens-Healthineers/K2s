#!/bin/bash

PROXY="$1"

echo "Setting proxy '$PROXY' for apt"

# Create proxy config file
sudo touch /etc/apt/apt.conf.d/proxy.conf

# Add proxy configuration
echo "Acquire::http::Proxy \"$PROXY\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null

echo "Proxy configuration completed successfully"