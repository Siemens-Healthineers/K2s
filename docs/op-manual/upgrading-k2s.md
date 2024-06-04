<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Upgrading *K2s*
## Versioning
The *k2s* CLI offers the possibility to upgrade your cluster from a previously released version to the next.
The [*K2s* Release Versions](https://github.com/Siemens-Healthineers/K2s/releases){target="_blank"} follow the format `MAJOR.MINOR.PATCH`.
The upgrade in general is only from `MINOR-1` to `MINOR` possible (same `MAJOR` version). Upgrading from older versions is also possible only by upgrading each intermediate version individually.

Upgrade is overall available starting from *K2s* `v1.0.0.`.

<figure markdown="span">
  ![Cluster Upgrade](assets/Upgrade.png){ loading=lazy }
  <figcaption>K2s Cluster Upgrade Versioning Semantics</figcaption>
</figure>

## Upgrading
!!! info
    Upgrading the *K8s* cluster migrates all existing resources from the "old" cluster to the "new" cluster automatically.

1. Extract the package containing the new *K2s* version to a folder
2. Open a command shell with administrator privileges inside that folder
3. Run:
    ```console
    k2s upgrade
    ```

All downloaded artifacts are cached on local disk by default (in case you want to re-install *K2s*). They can be deleted with the following option:
```console
k2s upgrade -d
```

In general the new cluster based on the new version will take over all settings available in the older cluster (like memory, CPU and storage settings).
If you want to overwrite those settings, pass in a config file similar to [Installing Using Config Files](installing-k2s.md#installing-using-config-files):
```console
k2s upgrade -c <my-config>.yaml
```

To specify an http proxy, run:
```console
k2s upgrade -p <proxy-to-use>
```

The following tasks will be executed:

1. Export of current workloads (global *K8s* resources and all *K8s* resources of all namespaces)
2. Keeping addons and their persistency to be re-enabled after cluster upgrade
3. Uninstall existing cluster
4. Install a new cluster based on the package version version
5. Import previously exported workloads
6. Enable addons and restore persistency
7. Check if all workloads are running
8. Finally check *K2s* cluster availability