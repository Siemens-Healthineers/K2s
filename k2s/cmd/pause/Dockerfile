# SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

ARG BASE
FROM ${BASE}
ADD pause.exe /pause.exe
ADD wincat.exe /Windows/System32/wincat.exe
ENV PATH="C:\Windows\system32;C:\Windows;"
ENTRYPOINT ["/pause.exe"]
