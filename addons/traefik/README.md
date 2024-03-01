<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# traefik

## Introduction

The `traefik` addon provides an implementation of the [Traefik](https://github.com/traefik/traefik) Ingress Controller. Traefik is a modern HTTP reverse proxy and load balancer that makes deploying and accessing microservices easy.

## Getting started

The traefik addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable traefik
```
## Creating ingress routes

Unlike the NGINX Ingress Controller, Traefik uses Custom Resource Definitions for defining ingress routes. How to create an ingress route can be found [here](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/).

## Access of the ingress controller

The ingress controller is configured so that it can be reached from outside the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway controller (ingress-nginx, traefik or gateway-nginx) in the k2s cluster at the same time since they use the same ports.
