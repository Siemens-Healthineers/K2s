REM SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
REM
REM SPDX-License-Identifier: MIT

@SET installationDirectory=%~dp0..
@SET installationDrive=%~d0

del %installationDrive%\k.zip
powershell -Command "Compress-Archive -Path '%installationDirectory%' -DestinationPath %installationDrive%\k.zip"