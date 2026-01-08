<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

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

This addon creates a central Gateway resource that handles both HTTP and HTTPS traffic:

**Gateway Configuration:**
- **Name**: `nginx-cluster-local` (in `nginx-gw` namespace)
- **HTTP Listener**: Port 80 - no certificate required
- **HTTPS Listener**: Port 443 - uses `k2s-cluster-local-tls` secret

The HTTPS listener uses a **self-signed certificate** that is automatically created during
addon installation. For development and testing, this self-signed certificate is sufficient.
For production use with proper certificate management, the security addon (cert-manager)
can be enabled to provision trusted certificates.

**Certificate Handling:**
- Without security addon: Self-signed certificate is created by Enable.ps1 using cert-manager
- With security addon: cert-manager can manage the certificate (replace self-signed cert)

For more details on Gateway API resources and routing patterns, see the
[Gateway API documentation](https://gateway-api.sigs.k8s.io/).

## Access of the gateway

The gateway is exposed via a LoadBalancer service with an external IP configured through
the NginxProxy resource. The external IP is dynamically set during installation based on
the K2s control plane IP (typically `172.19.1.100`).

**How External IP is Configured:**
1. Enable.ps1 retrieves the control plane IP
2. NginxProxy resource template is populated with this IP
3. When the Gateway is created, it triggers the data plane deployment
4. The data plane service is created with the external IP from NginxProxy configuration

**Access Points:**
- HTTPS: `https://172.19.1.100:443` or `https://k2s.cluster.local`

_Note:_ Only one ingress or gateway controller can be enabled at a time in K2s
(nginx ingress, traefik ingress, or nginx-gw) since they all use the same external IP and ports.

### TLS/HTTPS Configuration

The addon creates a Gateway with both HTTP and HTTPS listeners by default.

**Frontend TLS (Browser → Gateway):**
- **Self-signed certificate** is automatically created during installation
- Certificate CN: `k2s.cluster.local`
- Secret name: `k2s-cluster-local-tls` (in `nginx-gw` namespace)
- Browser access: `https://k2s.cluster.local` (accept browser certificate warning)

**Backend TLS (Gateway → Services):**
When HTTPRoutes reference HTTPS backend services, a **BackendTLSPolicy** must be configured
to enable secure backend connections. This is handled automatically by addons that require it.

Example: The dashboard addon configures BackendTLSPolicy to connect to kong-proxy:443:
- Extracts kong's certificate during installation
- Creates `kong-ca-cert` ConfigMap with the CA certificate
- BackendTLSPolicy references this ConfigMap for certificate validation

**Certificate Management Options:**

1. **Self-signed (default)**: Works immediately after installation for development/testing
   - Frontend: Self-signed cert created by Enable.ps1
   - Backend: Service-specific certificates validated via BackendTLSPolicy

2. **cert-manager (production)**: Enable the security addon for automatic certificate management
   - Frontend: Replace k2s-cluster-local-tls with cert-manager Certificate
   - Backend: cert-manager can provision certificates for backend services
   - See also [Security Addon](../../security/README.md)

### Shared Hostname Pattern

Web applications can use the shared hostname `k2s.cluster.local` in their HTTPRoute rules
and do not need to manage frontend TLS certificates themselves, since TLS termination is handled
centrally by the gateway. Multiple HTTPRoutes using the same hostname will be processed
by the gateway controller - the key requirement is to have **distinct path matching rules**
to avoid conflicts.

**Important:** If your backend service uses HTTPS (like kong-proxy, some API servers), you must
configure a BackendTLSPolicy to enable secure communication between the gateway and backend.
See the dashboard addon for a complete example of BackendTLSPolicy configuration.

All K2s addons with a web UI use this pattern and are configured to be reachable
under path-based routing: `k2s.cluster.local/<nameOfAddon>/`

Making web applications available under different paths can be challenging and may
require different approaches depending on the application. Each K2s addon demonstrates
a different technique for achieving path-based routing. The HTTPRoute and BackendTLSPolicy
resource definitions are worth analyzing to understand these mechanisms:

- **Kubernetes Dashboard**:
  - HTTPRoute: [dashboard-nginx-gw.yaml](../../dashboard/manifests/ingress-nginx-gw/dashboard-nginx-gw.yaml)
  - BackendTLSPolicy: [dashboard-backend-tls.yaml](../../dashboard/manifests/ingress-nginx-gw/dashboard-backend-tls.yaml)
  - Shows: Path rewrite, header modification, HTTPS backend with certificate validation

These examples show various routing patterns including path rewrites, header modifications,
backend service configurations, and secure backend communication with BackendTLSPolicy.

## Further Reading

- [Kubernetes Gateway API Official Documentation](https://gateway-api.sigs.k8s.io/) -
  Comprehensive guide to the Gateway API specification, concepts, and best practices
- [NGINX Gateway Fabric Documentation](https://docs.nginx.com/nginx-gateway-fabric/) -
  Official documentation for NGINX Gateway Fabric, including configuration guides and examples
- [NGINX Gateway Fabric GitHub Repository](https://github.com/nginxinc/nginx-gateway-fabric) -
  Source code, issue tracking, and community contributions
- [Gateway API Guides](https://gateway-api.sigs.k8s.io/guides/) -
  Practical guides for common routing scenarios (HTTP routing, traffic splitting, etc.)

