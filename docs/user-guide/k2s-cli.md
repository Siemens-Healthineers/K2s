<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# k2s CLI
The *k2s* CLI is a tool shipped with *K2s* to completely manage a *K2s* cluster, providing features like:

- install/uninstall/upgrade *K2s*
- start/stop/check status of *K2s*
- manage addons
- manage container images
- maintain host system and K8s cluster

It also provides an extensive help for all available commands and parameters/flags. Simply run:
```console
<repo>\k2s.exe -h
```

!!! tip
    When *K2s* is installed, the executables including *k2s* CLI have been added to `PATH`, so that the CLI can be called by using its name only:
    ```console
    k2s -h
    ```

!!! note
    Most of the *k2s* CLI commands require administrator privileges.