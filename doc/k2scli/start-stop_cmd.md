<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../../README.md)

# Starting Kubernetes Cluster
The *K2s* CLI tool provides an extensive help for all available commands and parameters/flags:
```
<installation folder>\k2s -h
```
 
To start Kubernetes, you need to run:

```
.\k2s start
```


# Stopping Kubernetes Cluster

To stop Kubernetes, you need to run:

```
<installation folder>\k2s stop
```


> **Note:** It is recommended to **STOP THE CLUSTER BEFORE [SHUTTING DOWN|SUSPENDING|HYBERNATING] YOUR HOST SYSTEM** to avoid Windows networking issues!
# Inspect Cluster Status
To check the cluster's health status, run:

```
<installation folder>\k2s status
```

To display additional health status information, run:

```
<installation folder>\k2s status -o wide
```
The output will be similar to the following:

![Status Command Output](/doc/k2scli/img/status_cmd_output.png)

&larr;&nbsp;[Install/Uninstall K2s](./install-uninstall_cmd.md)&nbsp;&nbsp;&nbsp;&nbsp;|&nbsp;&nbsp;&nbsp;&nbsp;[Home](../../README.md)&nbsp;&rarr;