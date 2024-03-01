<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# kubevirt

## Introduction

The `kubevirt` addon provides the possibility to deploy virtual machines in the k2s cluster. [KubeVirt](https://kubevirt.io/) technology addresses the needs of development teams that have adopted or want to adopt Kubernetes but possess existing virtual machine-based workloads that cannot be easily containerized. More specifically, the technology provides a unified development platform where developers can build, modify, and deploy applications residing in both application containers as well as virtual machines in a common, shared environment.

## Getting started

The kubevirt addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable kubevirt
```

## Using KubeVirt

An example how to deploy virtual machines in Kubernetes can be found [here](https://kubevirt.io/labs/kubernetes/lab1.html).

## Building your own virtual machine image

In order to run a virtual machine as pod inside Kubernetes a virtual machine image has to be created like container images for containers.
For this k2s provides a Powershell script `K2s/addons/kubevirt/BuildKubevirtImage.ps1`. With this script it is possible to build a virtual image from `qcow2` image:

```
.\BuildKubevirtImage.ps1 -InputQCOW2Image E:\QCOW2\windows20h2.qcow2 -ImageName virt-win20h2
```