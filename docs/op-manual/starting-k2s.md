<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Starting *K2s*
To start the *K8s* cluster and all accompanying services, run:
```console
k2s start
```

!!! note
    *K2s* will start automatically after the installation has finished.

### Additional Options

#### Skip Starting if Already Running
To skip starting the *K2s* cluster if it is already running, use the `--ignore-if-running` flag or its shortcut `-i`:
```console
k2s start --ignore-if-running
```
or
```console
k2s start -i
```

!!! note
    This option is useful to avoid unnecessary restarts of the cluster when it is already running.  