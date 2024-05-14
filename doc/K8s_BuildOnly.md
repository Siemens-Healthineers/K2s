<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../README.md)

# Build Only Setup (no Kubernetes cluster, build containers through k2s CLI) 

The Build Only Setup is designed for scenarios where a Kubernetes (K8s) cluster is unnecessary, 
as it enables the building of Windows and Linux containers without the need for such a cluster.

# Install Build Only Setup

Create main directory and download K2s repository:

```
mkdir c:\k2s& cd c:\k2s
git clone https://github.com/Siemens-Healthineers/K2s .
```

Install Build Only Setup:

```
k2s install buildonly
```

After installation Linux & Windows container images can be build with BuildImage (bi). 

Build Linux container from current directory:

```
k2s image build --image-tag 1
```

or

```
bi -tag 1
```

More details on BuildImage (bi): [Build a container](/doc/K8s_BuildingAContainer.md)

Uninstall Build Only Setup:

```
k2s uninstall
```
