# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Build context requirements:
#   - fluent-bit.exe 

ARG BASE="mcr.microsoft.com/oss/kubernetes/windows-host-process-containers-base-image:v1.0.0"
FROM $BASE

ENV PATH="C:\\Windows\\system32;C:\\Windows;"
COPY fluent-bit.exe .
ENTRYPOINT ["fluent-bit.exe"]
