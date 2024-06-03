<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

K2s Features
==============
[ Home ](../README.md)

**K2s** includes the following features:
- support of mixed Windows and Linux K8s (Kubernetes) workloads
- support for multiple Windows 10,11 and Server OS versions
- multiple network card support, including support for LAN and WIFI network interfaces
- offline support by being able to operate the K8s cluster and workloads without internet connectivity
- [Building a Container Image](../docs/user-guide/building-container-image.md) for building and testing Windows and Linux containers
- [rich set of addons](../addons/README.md) which can be used optionally for additional functionality 
- K2s supports 3 different [Hosting Variants](../docs/user-guide/hosting-variants.md)
- HTTP proxy support in entire functionality
- debugging helpers for analyzing network connectivity
- status information on cluster availability
- acceptance tests for ensuring full functionality of the cluster
- helpers for setting up K8s cluster for on-premises bare metal nodes and in the cloud using Azure Kubernetes Service
- template based setup of the different variants through yaml files
- main configuration possibility with central JSON config file
- improved overall DNS support and extension possibilities with custom DNS servers
- overall http(s) extension support for intranet resources or custom locations 
- optional functionality for the K8s cluster in form of [K2s Addons](../addons/README.md)

