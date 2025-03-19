<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# login servive providing login UI 
### build it
bgo.cmd -ProjectDir "c:\ws\k2s\k2s\cmd\login" -ExeOutDir "c:\ws\k2s\k2s\cmd\login"
### download hydra
.\DownloadandExtractHydra.ps1
### build container with k2s
k2s image build --windows --input-folder . --image-tag 0.1.0 -p