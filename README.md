<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# K2s (Kubernetes) Setup 
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml)

This **K2s** solution is a Kubernetes (K8s) distribution which packages different components
into one small and easy to use solution. It has its focus on running mixed Windows & Linux workloads in Kubernetes and it's available on Windows hosts.

## Why this **K2s** distribution ?

The problems that **K2s** solves are the following:
1. It offers the possibility to build a K8s cluster by reusing the Windows host as a node.
By this no extra Windows license is needed for a mixed Windows & Linux cluster
2. Offline support for all of the use cases (no internet connection needed)
3. It offers an easy path for migrating bare metal Windows applications to K8s workloads
4. Very low footprint by only having one virtual machine for the Linux workloads (Hyper-V or WSL)
5. It's build on 100% open source, no additional licenses needed

The name **K2s** comes from the fact that we start with the default setting of 2 K8s nodes (Windows & Linux) and it relates to K8s with the intention to solve the problems mentioned above.

See [Features](/doc/K8s_Features.md) for a full list of features.

## Quickstart

Extract the downloaded [K2s.zip](https://github.com/Siemens-Healthineers/K2s/releases) file to a folder of your choice (use **C:** drive if possible), open one command prompt as Administrator and navigate to that installation folder. 

Install **K2s** with (please check first [Prerequisites](./doc/k2scli/install-uninstall_cmd.md#prerequisites)):
```
<installation folder>\k2s install
```

After installation you can use one of the [shortcuts](./doc/K8s_Shortcuts.md) to interact with your new cluster:
```
k   - shows the commands available for interacting with the K8s cluster
ks  - get the state of the cluster
kgn - show the nodes of the cluster
kgp - show all the pods running in the cluster
...
```

Beside the raw K8s cluster we are also providing a [rich set of addons](./addons/README.md), which are bringing additional specific functionality to your cluster.
Enabling such an addon is very easy:
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

Uninstalling the cluster removes all the workloads in the cluster as well as the cluster itself:
```
<installation folder>\k2s uninstall
```

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

2. **Multi VM Variant**: for each node one virtual machine is created, minimum we have one Windows and one Linux node. Memory usage here starts at 10GB.
<br>![Image](/doc/assets/VariantMultiVM400.jpg)<br>

3. **Development Only Variant**: in this variant we don't create a K8s cluster, only the environment to be able to build and test Windows and Linux containers.
<br>![Image](/doc/assets/VariantDevOnly400.jpg)<br>

In addition to offering a K8s cluster setup, the **K2s** solution also provides tools for building and testing Windows and Linux container (checkout the ```k2s image``` command options).

For development only cases where no K8s is needed and the focus is only on building and testing containers (Windows & Linux), **K2s** offers a
way to do that.

## Further Usage
- [Get K2s](doc/K8s_Get-K2s.md)
- [Install K2s](doc/k2scli/install-uninstall_cmd.md#installing-small-k8s-setup-natively)
- [Start K2s](doc/k2scli/start-stop_cmd.md) (optional, K8s cluster starts automatically after installation)
- [Inspect Cluster Status](doc/k2scli/start-stop_cmd.md#inspect-cluster-status)
- [Stop K2s](doc/k2scli/start-stop_cmd.md#stopping-kubernetes-cluster)
- [Uninstall K2s](doc/k2scli/install-uninstall_cmd.md#uninstalling-small-k8s-setup)
- [Add a registry](doc/K8s_AddRegistry.md)
- [Build a container image](doc/K8s_BuildingAContainer.md)
- [Shortcuts for interacting with cluster](doc/K8s_Shortcuts.md)
- [Upgrading your cluster](doc/K8s_Upgrade.md)

## Addons
K2s provides a [rich set of addons](./addons/README.md) which are containing specific functionality, checkout the ```k2s addons``` command for all options.
These addons can be used for testing and rapid prototyping purposes, as well in selected product scenarios.

## Troubleshoot
- [Troubleshoot](doc/K8s_Troubleshoot.md)

## Contribute
- [Contributor Guide](doc/contributing/CONTRIBUTING.md)

## Training for Kubernetes
- [Kubernetes Trainings](doc/K8s_Trainings.md)

