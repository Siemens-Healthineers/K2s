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

### Windows reboot recovery and SSH

Windows startup recovery uses SSH to inspect and restore control-plane routes.
*K2s* restricts its private SSH key to the built-in Administrators group and
LOCAL SYSTEM, with inheritance disabled, so both elevated CLI commands and
the startup service can use it. Existing keys are secured before SSH or SCP
access without regenerating the key.

If the key cannot be secured or SSH authentication fails, recovery logs the
failure instead of treating it as a missing route. Resolve the reported SSH
error before retrying `k2s start`; restarting flannel cannot repair an
authentication failure.

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