# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT
#
# Convenience wrapper for the native Linux build (see build.sh).

.PHONY: build clean help

# Default target: build all Linux executables.
build:
	./build.sh

# Remove the binaries produced by build.sh.
clean:
	rm -f ./bin/k2s ./bin/cloudinitisobuilder ./bin/httpproxy ./bin/yaml2json

help:
	@echo "Targets:"
	@echo "  build   Build the Linux K2s executables natively (runs ./build.sh)."
	@echo "  clean   Remove the binaries produced by build."
