<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# ingress-nginx

## Introduction

The `ingress-nginx` addon provides an implementation of the [Ingress NGINX Controller](https://github.com/kubernetes/ingress-nginx). An Ingress controller acts as a reverse proxy and load balancer. It implements a Kubernetes Ingress. The ingress controller adds a layer of abstraction to traffic routing, accepting traffic from outside the Kubernetes platform and load balancing it to pods running inside the platform.

## Getting started

The ingress-nginx addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable ingress-nginx
```
## Creating ingress routes

The Ingress NGINX Controller supports standard Kubernetes networking definitions in order to reach cluster workloads. How to create an ingress route can be found [here](https://kubernetes.io/docs/concepts/services-networking/ingress/).

## Access of the ingress controller

The ingress controller is configured so that it can be reached from outside the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway controller (ingress-nginx, traefik or gateway-nginx) in the k2s cluster at the same time since they use the same ports.

## Further Reading
- [Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [NGINX Ingress Controller](https://docs.nginx.com/nginx-ingress-controller/)
