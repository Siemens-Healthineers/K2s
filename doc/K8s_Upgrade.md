<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../README.md)

# Upgrade your cluster from previous released version

The K2s CLI **upgrade** command offers the possibility to upgrade your cluster from the previous released version.
Having the released versions using the semantic versioning 2.0.0 concept, we use the format MAJOR.MINOR.PATCH for all the released versions of K2s.
Upgrade in general is only from MINOR-1 to MINOR possible (same MAJOR version). Upgrading from older versions is also possible only by upgrading each intermediate version individually.

Upgrade is overall available starting from the K2s version 1.0.0 !

![Image](/doc/assets/upgrade.png)
***<p style="text-align: center;">Upgrading your K8s cluster moves all resources to new cluster</p>***

# Main usage of upgrade command

After extracting new version of K2s to one folder, open a command shell located in that folder:

```
k2s upgrade -o
```

All downloaded artifacts are cached on local disk by default (if you want to reinstall often). They can be deleted with the following option:

```
k2s upgrade -d -o
```

In general the new cluster based on the new version will take over all settings available in the older cluster (like memory, CPU and storage settings).
If you want to overwrite those settings also a extra config file for the creation of the new cluster can be specified (config file has the same format like for the install command):

```
k2s upgrade -o -c my-cluster-config
```

In case of networks using a http proxy

```
k2s upgrade -o -p PROXY
```

# Steps in upgrading you cluster

By invoking the upgrade command the following steps are executed:
1. Export current workloads from existing cluster:
Here are resources from all namespaces are exported and kept for the duration of the upgrade. In addition also all global resources are also exported.

2. Keep enabled addons and their persistency in order to be able to enable these addons after upgrade

3. Uninstall existing cluster with version MAJOR.MINOR-1.PATCH

4. Install a new cluster based on the new version MAJOR.MINOR.PATCH

5. Import previous exported workloads from steps 1

6. Enable addons and restores persistency from step 2

7. Check if all workloads are running

8. Final check on cluster availability


