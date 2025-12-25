<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# ingress nginx-gw

## Introduction

The `ingress nginx-gw` addon provides an implementation of the Kubernetes Gateway API
using [NGINX Gateway Fabric](https://github.com/nginxinc/nginx-gateway-fabric).

### What is NGINX Gateway Fabric?

NGINX Gateway Fabric is a modern, production-ready implementation of the Kubernetes Gateway API
that leverages NGINX as its data plane. It is developed and maintained by NGINX, Inc. (part of F5).

**Key Features:**
- **Gateway API Conformance**: Fully implements the Gateway API specification, providing a
  standardized approach to traffic management
- **NGINX Data Plane**: Uses the proven NGINX reverse proxy and load balancer as its
  underlying engine for high performance and reliability
- **Dynamic Configuration**: Automatically configures NGINX based on Gateway API resources
  (Gateway, HTTPRoute, etc.) without requiring manual NGINX configuration
- **Multi-tenancy**: Supports multiple teams sharing the same gateway infrastructure
  with namespace-based isolation
- **Production-Grade**: Built for enterprise use with strong stability, security,
  and performance characteristics

### How it Works

NGINX Gateway Fabric acts as a reverse proxy and load balancer at the edge of your Kubernetes cluster:

1. **Traffic Ingress**: Accepts incoming traffic from outside the cluster via an external IP
2. **Route Matching**: Evaluates incoming requests against configured HTTPRoute rules
   (hostname, path, headers, etc.)
3. **Load Balancing**: Distributes traffic to appropriate backend pods using NGINX's
   load balancing capabilities
4. **TLS Termination**: Handles SSL/TLS encryption at the gateway level, offloading
   this from backend services

The gateway controller watches Gateway API resources in Kubernetes and dynamically
generates NGINX configuration, eliminating manual configuration management.

## Getting started

The ingress nginx-gw addon can be enabled using the `k2s` CLI
by running the following command:

```cmd
k2s addons enable ingress nginx-gw
```

## Creating Gateway API routes

NGINX Gateway Fabric uses the standard Kubernetes Gateway API resources to define
traffic routing rules:

- **Gateway**: Defines the load balancer/proxy infrastructure (listeners, ports, protocols)
- **HTTPRoute**: Defines HTTP traffic routing rules (hostname, path matching, backends)
- **ReferenceGrant**: Allows routes to reference resources in other namespaces (if needed)

### Gateway Resources

This addon provides two pre-configured Gateway resources:

- **cluster-local-nginx-gw.yaml**: HTTP-only gateway (port 80) - ready to use without certificates
- **cluster-local-nginx-gw-secure.yaml**: HTTP (port 80) and HTTPS (port 443) gateway - requires
  the `k2s-cluster-local-tls` certificate secret (created by cert-manager when the security addon is enabled)

Both gateways listen on hostname `k2s.cluster.local` and allow routes from all namespaces.

### Creating HTTPRoutes

To expose a service via the gateway, create an HTTPRoute resource that references
the Gateway. Example:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app-route
  namespace: my-namespace
spec:
  parentRefs:
  - name: nginx-cluster-local
    namespace: nginx-gw
  hostnames:
  - k2s.cluster.local
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /my-app/
    backendRefs:
    - name: my-app-service
      port: 8080
```

For more details on Gateway API resources and routing patterns, see the
[Gateway API documentation](https://gateway-api.sigs.k8s.io/).

## Access of the gateway

The gateway is exposed via a LoadBalancer service and configured to be reachable
from outside the cluster using the external IP address `172.19.1.100`.

**Access Points:**
- HTTP: `http://172.19.1.100:80` or `http://k2s.cluster.local` (when using the HTTP-only gateway)
- HTTPS: `https://172.19.1.100:443` or `https://k2s.cluster.local` (when using the secure gateway with cert-manager)

_Note:_ Only one ingress or gateway controller can be enabled at a time in K2s
(nginx ingress, traefik ingress, or nginx-gw) since they all use the same external IP and ports.

### TLS/HTTPS Configuration

This addon supports two deployment modes:

1. **HTTP-only (default)**: Uses `cluster-local-nginx-gw.yaml` which provides HTTP on port 80.
   No certificate configuration needed - works immediately after addon installation.

2. **HTTP + HTTPS (secure)**: Uses `cluster-local-nginx-gw-secure.yaml` which provides both
   HTTP (port 80) and HTTPS (port 443). Requires the `security` addon to be installed for
   automatic certificate provisioning via cert-manager.

When the security addon is enabled, cert-manager automatically creates and manages the
`k2s-cluster-local-tls` certificate secret. This certificate is used by the HTTPS listener
for TLS termination at the gateway level.

**Without cert-manager:** The HTTP-only gateway works perfectly for testing and development.
Simply access services via `http://k2s.cluster.local`.

**With cert-manager (security addon):** Services are accessible via both HTTP and HTTPS,
with automatic certificate management. See also [Security Addon](../../security/README.md).

### Shared Hostname Pattern

Web applications can use the shared hostname `k2s.cluster.local` in their HTTPRoute rules
and do not need to manage TLS certificates themselves, since TLS termination is handled
centrally by the gateway. Multiple HTTPRoutes using the same hostname will be processed
by the gateway controller - the key requirement is to have **distinct path matching rules**
to avoid conflicts.

All K2s addons with a web UI use this pattern and are configured to be reachable
under two endpoint styles:

- Dedicated subdomain: `k2s-<nameOfAddon>.cluster.local/`
- Shared path-based: `k2s.cluster.local/<nameOfAddon>/`

Making web applications available under different paths can be challenging and may
require different approaches depending on the application. Each K2s addon demonstrates
a different technique for achieving path-based routing. The HTTPRoute resource definitions
are worth analyzing to understand these mechanisms:

- **Kubernetes Dashboard**:
  [dashboard-nginx-gw.yaml](../../dashboard/manifests/ingress-nginx-gw/dashboard-nginx-gw.yaml)
- **Logging** (OpenSearch Dashboards):
  Check addon manifests for HTTPRoute examples
- **Monitoring** (Plutono/Grafana):
  Check addon manifests for HTTPRoute examples

These examples show various routing patterns including path rewrites, header modifications,
and backend service configurations.

## Further Reading

- [Kubernetes Gateway API Official Documentation](https://gateway-api.sigs.k8s.io/) -
  Comprehensive guide to the Gateway API specification, concepts, and best practices
- [NGINX Gateway Fabric Documentation](https://docs.nginx.com/nginx-gateway-fabric/) -
  Official documentation for NGINX Gateway Fabric, including configuration guides and examples
- [NGINX Gateway Fabric GitHub Repository](https://github.com/nginxinc/nginx-gateway-fabric) -
  Source code, issue tracking, and community contributions
- [Gateway API Guides](https://gateway-api.sigs.k8s.io/guides/) -
  Practical guides for common routing scenarios (HTTP routing, traffic splitting, etc.)

