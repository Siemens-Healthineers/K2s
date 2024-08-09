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

## Disruption in networking
When there is no internet access on the host machine or when container images cannot be pulled, it is recommended to restart the cluster networking in the following scenarios:

- The host machine is switched between networks (e.g. remote or office).
- The host machine experiences an unintended crash.
- After booting the host machine from hibernation, or following a reboot or shutdown.
- The VPN on the host machine is turned on or off (e.g., Zscaler).

```console
k2s stop
k2s start
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
