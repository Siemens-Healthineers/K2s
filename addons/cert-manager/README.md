<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# cert-manager

This k2s addon installs [cert-manager](https://cert-manager.io/), an X.509 certificate manager for Kubernetes.  

## Introduction

`cert-manager` provides APIs for obtaining and renewing TLS `Certificates` (modeled as K8s `CRD`), using one of many supported `issuers`.

It supports certificate provisioning based on annotations for certain Kubernetes resources like ingress, gateway and some service meshes. `cert-manager` observes these annotations and automates obtaining or renewal of certificates.

This addon configures a cluster-wide [CA Issuer](https://cert-manager.io/docs/configuration/ca/), which means it can be used from all kubernetes namespaces.

The addon also imports the public certificate of the CA Issuer into the trusted authorities of your windows host.

## Getting Started

The `cert-manager` addon can be enabled using the `k2s` CLI:

```cmd
k2s addons enable cert-manager
```

## How to use it

In terms of cert-manager, as described here: <https://cert-manager.io/docs/>, this addon configures a global `ClusterIssuer` of type CA (Certification Authority) named: **k2s-ca-issuer**

If you have also enabled the `ingress-nginx` and `dashboard` addons, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon:

<https://k2s-dashboard.local>

To use the cert-manager to secure the ingress to your kubernetes application, follow [this description](https://cert-manager.io/docs/usage/ingress/#how-it-works):

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

You can also use the command line interface `cmctl.exe` to interact with cert-manager, it was installed in the `bin\exe` path of your K2s install directory.

## Disable cert-manager

The cert-manager addon can be disabled using the k2s CLI:

```cmd
k2s addons disable cert-manager
```

## Further Reading

- Docs: <https://cert-manager.io/docs/>
- Code: <https://github.com/cert-manager/cert-manager>
