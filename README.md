<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# K2s - Kubernetes distribution for Windows & Linux workloads
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-reuse-checks.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-reuse-checks.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/ci-unit-tests.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-cli.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-k2s-artifacts.yml)
[![ci](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-docs.yml/badge.svg)](https://github.com/Siemens-Healthineers/K2s/actions/workflows/build-docs.yml)

**K2s** is a Kubernetes distribution which packages different open-source components into one small and easy to use solution focusing on running mixed Windows-based & Linux-based workloads in Kubernetes. 

This solution is installable on Windows hosts.

Read the [*K2s* Documentation](https://siemens-healthineers.github.io/K2s/).

## Why **K2s** distribution?
The problems that **K2s** solves are the following:
1. It provides the option to construct a K8s cluster by reusing the Windows host as a node. This eliminates the need for an extra Windows license in the case of a mixed Windows & Linux cluster.
2. Offline support is available for all use cases, eliminating the requirement for an internet connection.
3. It offers an easy path for migrating bare metal Windows applications to K8s workloads.
4. It maintains a low footprint by utilizing a single virtual machine for Linux workloads. (Hyper-V or WSL).
5. It is built on 100% open source technology, requiring no additional licenses.

The name **K2s** comes from the fact that we start with the default setting of 2 K8s nodes (Windows & Linux) and it relates to K8s with the intention to solve the problems mentioned above.

See [Features](docs/index.md#features) for a list of features.

## Quick Start
1. [Getting *K2s*](docs/op-manual/getting-k2s.md)
3. Verify that the [Prerequisites](docs/op-manual/installing-k2s.md#prerequisites) are fulfilled
4. Run as administrator in the installation/repository folder
    ```console
    k2s.exe install
    ```

After installation, you can utilize one of the [CLI Shortcuts](docs/user-guide/cli-shortcuts.md) to interact with your newly created cluster:
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
Checkout how to create such offline packages: [Creating Offline Package](docs/op-manual/creating-offline-package.md).

## [Supported OS Versions](docs/op-manual/os-support.md)
See also [*Windows*-based Images](./smallsetup/ps-modules/windows-support/README.md).

## [Hosting Variants](docs/user-guide/hosting-variants.md)

## Further Usage
- [Getting *K2s*](docs/op-manual/getting-k2s.md)
- [Installing *K2s*](docs/op-manual/installing-k2s.md)
- [Starting *K2s*](docs/op-manual/starting-k2s.md)
- [Checking *K2s* Status](docs/op-manual/checking-k2s-status.md)
- [Stopping *K2s*](docs/op-manual/stopping-k2s.md)
- [Uninstalling *K2s*](docs/op-manual/uninstalling-k2s.md)
- [Adding a Container Registry](docs/user-guide/adding-container-registry.md)
- [Building a Container Image](docs/user-guide/building-container-image.md)
- [CLI Shortcuts](docs/user-guide/cli-shortcuts.md)
- [Upgrading *K2s*](docs/op-manual/upgrading-k2s.md)
- [Creating Offline Package](docs/op-manual/creating-offline-package.md)

## Addons
K2s provides a [rich set of addons](./addons/README.md) which are containing specific functionality, checkout the ```k2s addons``` command for all options.
These addons can be used for testing and rapid prototyping purposes, as well in selected product scenarios.

## [Troubleshooting](docs/troubleshooting.md)

## [Contributing](docs/dev-guide/contributing/index.md)

## Training for Kubernetes
- [Kubernetes Trainings](doc/K8s_Trainings.md)

