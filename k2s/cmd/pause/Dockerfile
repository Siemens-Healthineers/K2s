# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# ARG BASE
# FROM ${BASE}

ARG WINDOWS_VERSION
FROM mcr.microsoft.com/windows/nanoserver:${WINDOWS_VERSION}

ADD pause.exe /pause.exe
ADD wincat.exe /Windows/System32/wincat.exe
ENV PATH="C:\Windows\system32;C:\Windows;"
ENTRYPOINT ["/pause.exe"]
