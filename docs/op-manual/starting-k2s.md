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

### Windows Default Switch validation

On Windows, startup validates the Hyper-V Default Switch against the configured
K2s subnets before starting networking. If its IPv4 address is initially missing,
startup observes it for up to 120 seconds to allow Windows networking to initialize.
A conflicting switch is removed and revalidated before K2s networking starts.
If the switch remains absent, startup can continue; an existing switch without
an IPv4 address fails validation because its subnet cannot be checked.

Startup checks again before reporting success. This final check does not remove
networks: if a conflicting Default Switch appears during startup, startup reports
an error. After Windows networking has settled, retry `k2s start`.

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