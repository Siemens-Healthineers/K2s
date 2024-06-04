<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Diagnostics
## *K2s* System Status
To inspect the full *K2s* system status, run:
```console
k2s status -o wide
```

## Log Files
To analyze the log files, browse the directory `<install-drive>\var\log`. The main log file is `k2s.log`.

## Dumping *K2s* Debug Information
To dump *K2s* system information, run:
```console
k2s system dump
```

## Listing ALL PVCs
Get the list of all mounted volumes, their size and their namespace:
```console
kg pv
```

Get the list of all mounted volume claims and their current usage:
```console
kg pvc -A
```