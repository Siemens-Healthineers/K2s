<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Stopping *K2s*
To stop the *K8s* cluster and all accompanying services, run:
```console
k2s stop
```

!!! danger
    It is **highly recommended to stop K2s before (shutting down | suspending | hibernating) the Windows host system** to avoid *Windows* networking issues on the next host system startup!

    This is a known root cause for issues occurring while running *Windows*-based workloads after *K8s* cluster start.