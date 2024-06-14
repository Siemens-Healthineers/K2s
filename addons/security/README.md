<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# security addon - EXPERIMENTAL

Enables secure communication into / out of the cluster (basic) and inside the cluster (advanced).

In this version only basic security is provided on an experimental level.

Basic and Advanced security options for the addon will be added and improved in the next versions.

![Upstream - downstream](doc/downstream-upstream.drawio.png)

## Getting Started

The `security` addon can be enabled using the `k2s` CLI:

```cmd
k2s addons enable security
```

These addons have currently also web applications included: **dashboard**, **login** and **monitoring**.
In this version in order to test the basic security model on these addons they have to be enabled **before** the security addon is enabled !
In addition also the security settings where tested only with the **ingress-nginx** addon.

## Disable security

The `security` addon can be disabled using the k2s CLI:

```cmd
k2s addons disable security
```

After disabled security also please reset the policies (navigate to [chrome://net-internals/#hsts](chrome://net-internals/#hsts)) for the following domains:

```cmd
k2s.cluster.local, k2s-dashboard.local, k2s-logging.local, k2s-monitoring.local
```

## Services used

This addon installs services needed to secure the network communication by configuration. This includes:

- [cert-manager](https://cert-manager.io/) - services for certificate provisioning and renewing, based on annotations. `cert-manager` observes these annotations and automates obtaining and renewing certificates.

- [keycloak](https://www.keycloak.org/) - services for identity and access management. `keycloak` provides user federation, strong authentication, user management, fine-grained authorization, and more.

## How to use it

### Certificate Management

In terms of [cert-manager](https://cert-manager.io/docs/), this addon configures a global `ClusterIssuer` of type CA (Certification Authority) named: **k2s-ca-issuer**. This issuer can be used in annotations to obtain and renew certificates.  
See: [CA Issuer](https://cert-manager.io/docs/configuration/ca/)

The addon also imports the public certificate of the CA Issuer into the trusted authorities of your windows host, and installs the `cmctl.exe` CLI.

In order to secure the ingress to your *Kubernetes* application, follow [this description](https://cert-manager.io/docs/usage/ingress/#how-it-works):

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

cert-manager will observe annotations, create a certificate and store it in the secret named 'your-secret-name' so that the ingress class uses it.

If you enable one of `ingress-nginx` or `traefik`, and also the `dashboard` addons, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon: <https://k2s-dashboard.local>. This is done with [this manifest file](../dashboard/manifests/dashboard-nginx-ingress.yaml).

You can also use the command line interface `cmctl.exe` to interact with cert-manager, it is installed in the `bin\exe` path of your K2s install directory.

## Further Reading

- Docs: <https://cert-manager.io/docs/>
- Code: <https://github.com/cert-manager/cert-manager>
- Docs: <https://www.keycloak.org/documentation>
- Code: <https://github.com/keycloak/keycloak>

## Knowledge Base

- **HSTS:** Browsers keep track on several security-related properties of web sites. If they encounter weaker security settings that they encountered last time, they assume it is an attack and will not allow the navigation to that site. This is the case when you enable the security addon, browse a secure site of your cluster, and then disable the security addon. The browser will not trust the site you used before anymore.

  You can **reset HSTS** of your site stored by your browser by navigating to:

  ```cmd
  chrome://net-internals/#hsts
  ```

  and deleting the settings for your site.
