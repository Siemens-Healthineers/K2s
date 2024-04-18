<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# security

Enables secure communication into and inside the cluster

## Introduction

This addon installs services needed to secure the network communication into the cluster and inside the cluster by configuration. This includes:

- [cert-manager](https://cert-manager.io/) - services for certificate provisioning based on annotations, which can be used for TLS termination and service meshes. `cert-manager` observes these annotations and automates obtaining and renewing certificates.

  This addon configures a cluster-wide [CA Issuer](https://cert-manager.io/docs/configuration/ca/), which means it can be used from all kubernetes namespaces.

  The addon also imports the public certificate of the CA Issuer into the trusted authorities of your windows host, and installs the `cmctl.exe` CLI.

## Getting Started

The `security` addon can be enabled using the `k2s` CLI:

```cmd
k2s addons enable security
```

## How to use it

### Certificate Management

In terms of [cert-manager](https://cert-manager.io/docs/), this addon configures a global `ClusterIssuer` of type CA (Certification Authority) named: **k2s-ca-issuer**. This issuer can be used in annotations to obtain and renew certificates.

In order to secure the ingress to your kubernetes application, follow [this description](https://cert-manager.io/docs/usage/ingress/#how-it-works):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  annotations:
    ...
    cert-manager.io/cluster-issuer: k2s-ca-issuer
    cert-manager.io/common-name: your-ingress-host.domain
...
spec:
...
  tls:
  - hosts:
    - your-ingress-host.domain
    secretName: your-secret-name
```

cert-manager will observe annotations, create a certificate and store it in the secret named 'your-secret-name' so that nginx uses it.

If you enable the `ingress-nginx` and `dashboard` addons, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon: <https://k2s-dashboard.local>. This is done with [this manifest file](../dashboard/manifests/dashboard-nginx-ingress.yaml).

You can also use the command line interface `cmctl.exe` to interact with cert-manager, it was installed in the `bin\exe` path of your K2s install directory.

## Disable security

The `security` addon can be disabled using the k2s CLI:

```cmd
k2s addons disable cert-manager
```

## Further Reading

- Docs: <https://cert-manager.io/docs/>
- Code: <https://github.com/cert-manager/cert-manager>
