<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# gateway-api

## Introduction

The `gateway-api` addon provides an implementation of the [NGINX Gateway Fabric](https://github.com/nginxinc/nginx-gateway-fabric). It is an open-source project that provides an implementation of the [Gateway API](https://gateway-api.sigs.k8s.io/) using NGINX as the data plane. The goal of this project is to implement the core Gateway APIs to configure an HTTP or TCP/UDP load balancer, reverse-proxy, or API gateway for applications running on Kubernetes.

## Getting started

The gateway-api addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable gateway-api
```
## Creating a sample Gateway and HTTPRoute

The NGINX Gateway Fabric provides several examples which can be found [here](https://github.com/nginxinc/nginx-gateway-fabric/tree/main/examples).

## Access of the gateway controller

The gateway controller is configured so that it can be reached from outside the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway controller (ingress nginx, ingress traefik or gateway-api) in the k2s cluster at the same time since they use the same ports.