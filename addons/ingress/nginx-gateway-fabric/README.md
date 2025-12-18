<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# ingress nginx-gateway

## Introduction

The `ingress nginx-gateway` addon provides an implementation of the Kubernetes Gateway API
using [NGINX Gateway Fabric](https://github.com/nginxinc/nginx-gateway).
NGINX Gateway Fabric is a conformant implementation of the Gateway API that uses NGINX as the data plane.
It acts as a reverse proxy and load balancer, accepting traffic from outside the Kubernetes platform
and routing it to pods running inside the platform based on Gateway API resources.

## Getting started

The ingress nginx-gateway addon can be enabled using the `k2s` CLI
by running the following command:

```cmd
k2s addons enable ingress nginx-gateway
```

## Creating Gateway API routes

NGINX Gateway Fabric supports the Kubernetes Gateway API resources (Gateway, HTTPRoute, etc.)
for defining traffic routing rules.
For details on creating routes using the Gateway API, see the
[Gateway API documentation](https://gateway-api.sigs.k8s.io/).

## Access of the gateway

The gateway is configured so that it can be reached from outside
the cluster via the external IP Address `172.19.1.100`.

_Note:_ It is only possible to enable one ingress controller or gateway
controller (ingress nginx, ingress traefik or gateway-api) in the K2s cluster at the
same time since they use the same ports.

This Addon prepares one central TLS termination, matching the hostname
`k2s.cluster.local`, and using as certificate a secret named
`k2s-cluster-local-tls` which is configured to be created and updated by
`cert-manager` - if the `security` addon is installed.
If the security add-on is not installed, NGINX Gateway Fabric provides a default certificate.
See also [Security Addon](../../security/README.md).

Web applications can use this host name in their HTTPRoute rules
and do not need to care about TLS anymore, since it is handled by this
central gateway. All routes using the same hostname will be processed by the gateway
controller - so the only important thing is to have distinct path matching rules.

All Addons with a Web UI use this feature,
and are configured to be reachable under two endpoints:

- k2s-_nameOfAddOn_.cluster.local/
- k2s.cluster.local/_nameOfAddOn_/

Making web applications available under different paths is not trivial,
and might even not be possible. In fact, it turns out that each of the Addons
provided by K2s uses another mechanism to make this possible.
The Gateway API Resource definitions are worth being analyzed,
to understand the different mechanisms:

- Kubernetes Dashboard:
  [NGINX Gateway Fabric Routes](../../dashboard/manifests/nginx-gateway/dashboard-httproute.yaml).
- Logging:
  [NGINX Gateway Fabric HTTPRoute](../../logging/manifests/opensearch-dashboards/httproute.yaml).
- Monitoring:
  [NGINX Gateway Fabric HTTPRoute](../../monitoring/manifests/plutono/httproute.yaml).

## Further Reading

- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [NGINX Gateway Fabric Documentation](https://docs.nginx.com/nginx-gateway/)

