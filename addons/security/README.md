<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# security addon - EXPERIMENTAL

Enables secure communication into / out of the cluster (basic) and inside the cluster (advanced).  
Basic and Advanced security options for the addon will be added and improved in the next versions.

![Upstream - downstream](doc/downstream-upstream.drawio.png)

In this version only basic security is provided on an experimental level.

## Getting Started

The `security` addon can be enabled using the `k2s` CLI:

```cmd
k2s addons enable security
```

If security addons is enabled, the ingress endpoints on host `k2s.cluster.local`
are TLS-terminated with certificates managed by `cert manager`.  
Also these endpoints can be guarded by authentication based ok `keycloak`.  
Both features are demonstrated with these three K2s addons:
**dashboard**, **logging** and **monitoring**.  
The security addon can be enabled before or after any of the other addons -
it will refresh configurations of already enabled addons.

Keycloak features are implemented and tested only with the **ingress nginx** addon.

## Disable security

The `security` addon can be disabled using the k2s CLI:

```cmd
k2s addons disable security
```

After disabling the security addon, please reset the browser security policies
(navigate to [chrome://net-internals/#hsts](chrome://net-internals/#hsts)) for
the domain `k2s.cluster.local`.

## Services used by security addon

This addon installs services needed to secure the network communication by configuration. This includes:

- [cert-manager](https://cert-manager.io/) - services for certificate
  provisioning and renewing, based on annotations. `cert-manager` observes these
  annotations and automates obtaining and renewing certificates.

- [keycloak](https://www.keycloak.org/) - services for identity and access
  management. `keycloak` provides user federation, strong authentication, user
  management, fine-grained authorization, and more.

## How to use it

As mentioned above, these 3 addons make use of the security features provided:
**dashboard**, **monitoring** and **logging**.
Products can use them as examples on how to use the security addon to
secure their services and applications by configuration.

### Certificate Management

The K2s security addon installs [cert-manager](https://cert-manager.io/docs/),
and then configures a global `ClusterIssuer` of type CA (Certification Authority) named
**k2s-ca-issuer**.
This issuer can be used in annotations to obtain and renew certificates.  
See: [CA Issuer](https://cert-manager.io/docs/configuration/ca/)

The security addon also imports the public certificate of the CA Issuer
into the trusted authorities store of your windows host computer,
and installs the `cmctl.exe` CLI.

In order to secure the ingress to your *Kubernetes* application,
follow [this description](https://cert-manager.io/docs/usage/ingress/#how-it-works):

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

cert-manager will observe annotations, create a certificate and store it in the secret named
'your-secret-name' so that the ingress class uses it.

If you enable one of `ingress nginx` or `ingress traefik` addon, and also the `dashboard` addon, you can inspect the
server certificate by visiting the dashboard URL in your browser and clicking on the lock icon:
[https://k2s.cluster.local](https://k2s.cluster.local). This is done with
[this manifest file](../ingress/nginx/manifests/cluster-local-ingress.yaml).

You can also use the command line interface `cmctl.exe` to interact with cert-manager,
it is installed in the `bin` path of your K2s install directory.

### Authentication and Authorization

The K2s security addon installs [keycloak](https://www.keycloak.org/), configures a realm
named `demo_app` and creates two users in it: `demo_user` and `admin_user`,
both with password `password`.

In order to guard your application with a login prompt to this keycloak demo_app,
follow [these instructions](https://www.keycloak.org/getting-started/getting-started-kube)

As an example, we configure the `dashboard` K2s addon so that, if the `security` is also
enabled, the user will be forced to log in. This is achieved by extending the ingress
configuration [like this](../dashboard/manifests/ingress-nginx-secure/kustomization.yaml):

```yaml
- patch: |-
    - op: add
      path: "/metadata/annotations/nginx.ingress.kubernetes.io~1auth-url"
      value: "https://k2s.cluster.local/oauth2/auth"
    - op: add
      path: "/metadata/annotations/nginx.ingress.kubernetes.io~1auth-signin"
      value: "https://k2s.cluster.local/oauth2/start?rd=$escaped_request_uri"
    - op: add
      path: "/metadata/annotations/nginx.ingress.kubernetes.io~1auth-response-headers"
      value: "Authorization"
```

The endpoint `https://k2s.cluster.local/oauth2/auth` is an ingress endpoint
configured here:  
[addons\security\manifests\keycloak\nginx-ingress.yaml](manifests\keycloak\nginx-ingress.yaml),  
which in turn forwards the requests to this oauth2 proxy:  
[addons\security\manifests\keycloak\oauth2-proxy.yaml](manifests\keycloak\oauth2-proxy.yaml)  
which is configured to serve as ouath2 provider for the keycloak demo_app.

As a result, if the user navigates to the `dashboard` ingress endpoint:  
[https://k2s.cluster.local/dashboard/](https://k2s.cluster.local/dashboard/)  
The ingress controller will first challenge the user to log at  
[https://k2s.cluster.local/oauth2/start](https://k2s.cluster.local/oauth2/start)  
After a successful login, the user will be redirected to the url which was
originally requested, with the essential difference that now the Authorization
header is filled in with a valid Bearer Token.

The [Kubernetes Dashboard](https://github.com/kubernetes/dashboard/blob/master/docs/user/access-control/README.md)
is set up to use Kubernetes RBAC (Role Based Access Control).  
We configured the Role Mapping in such a way that the user `admin-user` has all
required roles, and the user `demo-user` has no role at all:  
[addons\dashboard\manifests\dashboard\role-bindings.yaml]( ..\dashboard\manifests\dashboard\role-bindings.yaml)

The `Kubernetes Dashboard` is using the Kubernetes API Server, which needs to
enforce that the calling user is indeed allowed to access the called API.
By default, this works if the calling user is a kubernetes service user.
For external users, then the kubernetes API server needs to contact the Open ID
issuer to verify the users identity claimed by the Authentication Token found in
the request.

For this, the security plugin re-configures the kubernetes api server by adding
these 3 parameters to its command line:

```cmd
--oidc-issuer-url=https://k2s.cluster.local/keycloak/realms/demo-app
--oidc-client-id=demo-client
--oidc-ca-file=/etc/kubernetes/pki/certmgr-ca.crt
```

Where the `certmgr-ca.crt` file contains the public key of the Cert Manager
ClusterIssuer described above, and `demo-client` is the ID of a client created
in  
[addons\security\manifests\keycloak\keycloak.yaml](manifests\keycloak\keycloak.yaml)

In order to test the behavior of the
[dashboard app](https://k2s.cluster.local/dashboard/),
navigate to it in private mode and try out these things:

- login with `admin-user` (password is `password`). You should have full functionality of the Dashboard.
- login with `demo-user` (password is also `password`). You should see the UI,
  but any action must be forbidden - including listing any K82 resource.
- try to log in with wrong credentials. You should not be able to navigate to
  see the dashboard UI at all.

## Further Reading

- Docs: <https://cert-manager.io/docs/>
- Code: <https://github.com/cert-manager/cert-manager>
- Docs: <https://www.keycloak.org/documentation>
- Code: <https://github.com/keycloak/keycloak>

## Knowledge Base

- **HSTS:** Browsers keep track on several security-related properties of web sites.
  If they encounter weaker security settings that they encountered last time,
  they assume it is an attack and will not allow the navigation to that site.
  This is the case when you enable the security addon, browse a secure site of
  your cluster, and then disable the security addon. The browser will not trust
  the site you used before anymore.

  You can **reset HSTS** of your site stored by your browser by navigating to:

  ```cmd
  chrome://net-internals/#hsts
  ```

  and deleting the settings for your site.
