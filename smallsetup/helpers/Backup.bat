REM SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
REM
REM SPDX-License-Identifier: MIT

@SET installationDirectory=%~dp0..
@SET installationDrive=%~d0

del %installationDrive%\k.zip
powershell -Command "Compress-Archive -Path '%installationDirectory%' -DestinationPath %installationDrive%\k.zip"