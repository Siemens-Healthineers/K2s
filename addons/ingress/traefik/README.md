<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# ingress traefik

## Introduction

The `ingress traefik` addon provides an implementation of the Ingress Controller with
[ingressClassName: traefik](https://github.com/traefik/traefik).
Traefik is a modern HTTP reverse proxy and load balancer that makes
deploying and accessing microservices easy.

## Getting started

The ingress traefik addon can be enabled using the `k2s` CLI by running the following command:

```cmd
k2s addons enable ingress traefik
```

## Creating ingress routes

In addition to implementing the Kubernetes `Ingress` Interface,
Traefik uses Custom Resource Definitions (CRD) to define several other
resource kinds like e.g. `IngressRoute` - see
[documentation](https://doc.traefik.io/traefik/routing/providers/kubernetes-crd/).

## Access of the ingress controller

The ingress controller is configured so that it can be reached from outside
the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway
controller (ingress nginx, ingress traefik or gateway nginx) in the K2s cluster at the
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
  [Traefik Ingress](../../dashboard/manifests/ingress-traefik/dashboard-traefik-ingress.yaml).
- Logging:
  [Traefik Ingress](../../logging/manifests/opensearch-dashboards/traefik.yaml).
- Monitoring:
  [Traefik Ingress](../../monitoring/manifests/grafana/traefik.yaml).
