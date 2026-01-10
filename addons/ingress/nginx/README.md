<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# ingress nginx

## Introduction

The `ingress nginx` addon provides an implementation of the Ingress Controller
with [ingressClassName: nginx](https://github.com/kubernetes/ingress-nginx).
An Ingress controller acts as a reverse proxy and load balancer.
It implements a Kubernetes Ingress.
The ingress controller adds a layer of abstraction to traffic routing,
accepting traffic from outside the Kubernetes platform and load balancing
it to pods running inside the platform.

## Getting started

The ingress nginx addon can be enabled using the `k2s` CLI
by running the following command:

```cmd
k2s addons enable ingress nginx
```

## Creating ingress routes

The Ingress NGINX Controller supports standard Kubernetes networking
definitions in order to reach cluster workloads.
How to create an ingress route can be found
[here](https://kubernetes.io/docs/concepts/services-networking/ingress/).

## Access of the ingress controller

The ingress controller is configured so that it can be reached from outside
the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway
controller (ingress nginx, ingress traefik or gateway-api) in the K2s cluster at the
same time since they use the same ports.

This Addon prepares one central TLS termination, matching the hostname
`k2s.cluster.local`, and using as certificate a secret named
`k2s-cluster-local-tls` which is configured to be created and updated by
`cert-manager` - if the `security` addon is installed.
If the security add-on is not installed, NGINX provides a default certificate.
See also [Security Addon](../../security/README.md).

Web applications can use this host name in their ingress rules
and do not need to care about TLS anymore, since it is handled by this
central ingress. All rules using the same host will me merged by the ingress
controller - so the only important thing is to have distinct Prefix rules.

All Addons with a Web UI use this feature,
and are configured to be reachable under two endpoints:

- k2s-_nameOfAddOn_.cluster.local/
- k2s.cluster.local/_nameOfAddOn_/

Making web applications available under different paths is not trivial,
and might even not be possible. In fact, it turns out that each of the Addons
provided by K2s uses another mechanism to make this possible.
The Ingress Resource definitions are worth being analyzed,
to understand the different mechanisms:

- Kubernetes Dashboard:
  [NGINX Ingresses](../../dashboard/manifests/ingress-nginx/dashboard-nginx-ingress.yaml).
- Logging:
  [NGINX Ingress](../../logging/manifests/opensearch-dashboards/ingress.yaml).
- Monitoring:
  [NGINX Ingress](../../monitoring/manifests/grafana/ingress.yaml).

## Further Reading

- [Services, Load Balancing, and Networking](https://kubernetes.io/docs/concepts/services-networking/)
- [NGINX Ingress Controller](https://docs.nginx.com/nginx-ingress-controller/)
