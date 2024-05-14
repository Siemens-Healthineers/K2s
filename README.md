<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# K2s (Kubernetes) Setup 
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-reuse-checks.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-reuse-checks.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml)

**K2s** solution is a Kubernetes (K8s) distribution which packages different components
into one small and easy to use solution. It has its focus on running mixed Windows & Linux workloads in Kubernetes and it's available on Windows hosts.

## Why **K2s** distribution ?

The problems that **K2s** solves are the following:
1. It provides the option to construct a K8s cluster by reusing the Windows host as a node. This eliminates the need for an extra Windows license in the case of a mixed Windows & Linux cluster.
2. Offline support is available for all use cases, eliminating the requirement for an internet connection.
3. It offers an easy path for migrating bare metal Windows applications to K8s workloads.
4. It maintains a low footprint by utilizing a single virtual machine for Linux workloads. (Hyper-V or WSL).
5. It is built on 100% open source technology, requiring no additional licenses.

The name **K2s** comes from the fact that we start with the default setting of 2 K8s nodes (Windows & Linux) and it relates to K8s with the intention to solve the problems mentioned above.

See [Features](/doc/K8s_Features.md) for a full list of features.

## Quickstart

Get **K2s** into a folder of your choice as [described here](doc/K8s_Get-K2s.md) (use **C:** drive if possible), open a command prompt as Administrator and navigate to the installation folder.

Install **K2s** with (ensure to verify the [Prerequisites](./doc/k2scli/install-uninstall_cmd.md#prerequisites) first):
```
<installation folder>.\k2s.exe install
```

After installation, you can utilize one of the [shortcuts](./doc/K8s_Shortcuts.md) to interact with your newly created cluster:
```
k   - shows the commands available for interacting with the K8s cluster
ks  - get the state of the cluster
kgn - show the nodes of the cluster
kgp - show all the pods running in the cluster
...
```

Beside the raw K8s cluster we are also providing a [rich set of addons](./addons/README.md), which are bringing additional specific functionality to your cluster.
Enabling such an addon is a straightforward process:
```
k2s addons ls                     - lists all the available addons
k2s addons enable ingress-nginx   - enables the ingress nginx ingress controller
...
```
Disabling the same addon:
```
k2s addons disable ingress-nginx   - disables the ingress nginx ingress controller
...
```

Uninstalling the cluster removes not only the cluster itself but also all the workloads within the cluster:
```
<installation folder>.\k2s uninstall
```

In case that multiple systems need to be provisioned with Kubernetes or you want to reduce the install time dramatically, it is better to create one **K2s** offline package (contains all downloaded artifacts) before starting the install command.
Setting up the Kubernetes cluster with the offline package takes only 2-3 minutes and needs no internet connection.
Checkout how to create such offline packages: [Offline packages](doc/K8s_OfflinePackages.md)

## Supported OS Versions
| Windows                 | Version | Build           |
| ----------------------- | ------- | --------------- |
| Windows 10, Server 2019 | 1809    | 10.0.17763.xxxx |
| Windows 10              | 2004    | 10.0.19041.xxxx |
| Windows 10              | 20H2    | 10.0.19042.xxxx |
| Windows 10              | 21H2    | 10.0.19044.xxxx |
| Windows 10              | 22H2    | 10.0.19045.xxxx |
| Windows Server 2022     | 21H2    | 10.0.20348.xxxx |
| Windows 11              | 21H2    | 10.0.22000.xxxx |
| Windows 11              | 22H2    | 10.0.22621.xxxx |
| Windows 11              | 23H2    | 10.0.22631.xxxx |

See also [Windows-based Images](./smallsetup/ps-modules/windows-support/README.md).

## Hosting variants:
1. **Host Variant**: On the Windows host, a single virtual machine is exclusively utilized as the Linux master node, while the Windows host itself functions as the worker node.
This variant is also the default, it offers very low memory consumption and efficiency. Memory usage starts at 4GB.
<br>![Image](/doc/assets/VariantHost400.jpg)<br>

2. **Multi VM Variant**: For each node, a virtual machine is created, with a minimum configuration of one Windows node and one Linux node. The memory usage for each node starts at 10GB.
<br>![Image](/doc/assets/VariantMultiVM400.jpg)<br>

3. **Development Only Variant**: In this variant, the focus is on setting up an environment solely for building and testing Windows and Linux containers without creating a K8s cluster.
<br>![Image](/doc/assets/VariantDevOnly400.jpg)<br>

In addition to offering a K8s cluster setup, the **K2s** solution also provides tools for building and testing Windows and Linux container (checkout the ```k2s image``` command options).

For development only cases where no K8s is needed and the focus is only on building and testing containers (Windows & Linux), **K2s** offers a
way to do that.

## Further Usage
- [Get K2s](doc/K8s_Get-K2s.md)
- [Install K2s](doc/k2scli/install-uninstall_cmd.md#installing)
- [Start K2s](doc/k2scli/start-stop_cmd.md) (optional, K8s cluster starts automatically after installation)
- [Inspect Cluster Status](doc/k2scli/start-stop_cmd.md#inspect-cluster-status)
- [Stop K2s](doc/k2scli/start-stop_cmd.md#stopping-kubernetes-cluster)
- [Uninstall K2s](doc/k2scli/install-uninstall_cmd.md#uninstalling)
- [Add a registry](doc/K8s_AddRegistry.md)
- [Build a container image](doc/K8s_BuildingAContainer.md)
- [Shortcuts for interacting with cluster](doc/K8s_Shortcuts.md)
- [Upgrading your cluster](doc/K8s_Upgrade.md)
- [Create offline packages](doc/K8s_OfflinePackages.md)

## Addons
K2s provides a [rich set of addons](./addons/README.md) which are containing specific functionality, checkout the ```k2s addons``` command for all options.
These addons can be used for testing and rapid prototyping purposes, as well in selected product scenarios.

## Troubleshoot
- [Troubleshoot](doc/K8s_Troubleshoot.md)

## Contribute
- [Contributor Guide](doc/contributing/CONTRIBUTING.md)

## Training for Kubernetes
- [Kubernetes Trainings](doc/K8s_Trainings.md)

