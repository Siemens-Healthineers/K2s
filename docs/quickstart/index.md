<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Quick Start
1. [Get *K2s*](../op-manual/getting-k2s.md)
3. Verify that the [Prerequisites](../op-manual/installing-k2s.md#prerequisites) are fulfilled
4. Run as administrator in the installation/repository folder:
    ```console
    k2s.exe install
    ```
5. Check *K2s* cluster health:
    ```console
    k2s.exe status
    ```
6. Deploy your workloads :rocket:

See [*k2s* CLI](../user-guide/k2s-cli.md) and [CLI Shortcuts](../user-guide/cli-shortcuts.md) for more means to interact with the *K2s* cluster.

Optionally, install one or more [*K2s* Addons](https://github.com/Siemens-Healthineers/K2s/blob/main/addons/README.md){target="_blank"} for additional functionality.

To create an offline installer first, check out [Creating Offline Package](../op-manual/creating-offline-package.md).