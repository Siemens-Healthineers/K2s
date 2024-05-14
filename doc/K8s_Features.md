<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

[Home](../README.md)

K2s Features
==============

**K2s** includes the following features:
- support of mixed Windows and Linux K8s (Kubernetes) workloads
- support for multiple Windows 10,11 and Server OS versions
- multiple network card support, including support for LAN and WIFI network interfaces
- offline support by being able to operate the K8s cluster and workloads without internet connectivity
- [image command](K8s_BuildingAContainer.md) for building and testing Windows and Linux containers
- [rich set of addons](../addons/README.md) which can be used optionally for additional functionality 
- K2s supports 3 variants in hosting:
    
    1. **Host Variant**: here on the Windows host only one Virtual Machine is created and used as the Linux master and worker node.
This variant is also the default, it offers very low memory consumption and efficiency. Memory usage starts at 4GB.
<br>![Image](/doc/assets/VariantHost400.jpg)<br>

    2. **Multi VM Variant**: for each node one virtual machine is created, minimum we have one Windows and one Linux node. Memory usage here starts at 10GB.
<br>![Image](/doc/assets/VariantMultiVM400.jpg)<br>

    3. **Development Only Variant**: in this variant we don't create a K8s cluster, only the environment to be able to build and test Windows and Linux containers.
<br>![Image](/doc/assets/VariantDevOnly400.jpg)<br>

- HTTP proxy support in entire functionality
- debugging helpers for analyzing network connectivity
- status information on cluster availability
- acceptance tests for ensuring full functionality of the cluster
- helpers for setting up K8s cluster for onpremise bare metal nodes and in the cloud using Azure Kubernetes Service
- template based setup of the different variants through yaml files
- main configuration possibility with central json config file
- improved overall DNS support and extension possibilities with custom DNS servers
- overall http(s) extension support for intranet resources or custom locations 
- optional functionality for the K8s cluster in form of [K2s Addons](../addons/README.md)

