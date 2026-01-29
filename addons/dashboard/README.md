<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# dashboard

## Introduction

The `dashboard` addon provides a Kubernetes Dashboard which is a general purpose, web-based UI for Kubernetes clusters. It allows users to manage applications runing in the cluster and troubleshoot them, as well as manage the cluster itself.

## Getting started

The Kubernetes dashboard can be enabled using the k2s CLI by running the following command:

```
k2s addons enable dashboard
```

### Intergration with metrics addon

By enabling the metrics addon, the dashboard addon can present the collected metrics in the dashboard UI.

The following commands enable the metrics addon and the dashboard addon:

```
k2s addons enable metrics
k2s addons enable dashboard
```

The metrics addon can be enabled while enabling the dashboard addon using the following command:

```
k2s addons enable dashboard --enable-metrics
```

### Integration with ingress nginx, ingress traefik and ingress nginx-gw addons

The dashboard addon can be integrated with either the ingress nginx, the ingress traefik, or the ingress nginx-gw addon so that it can be exposed outside the cluster.

For example, the dashboard can be enabled along with ingress traefik addon using the following command:

```
k2s addons enable dashboard --ingress traefik
```

Similarly, the dashboard can be enabled along with ingress nginx-gw addon using the following command:

```
k2s addons enable dashboard --ingress nginx-gw
```

_Note:_ The above commands shall enable the respective ingress addon if it is not enabled.

The dashboard addon can be integrated with either the ingress nginx, the ingress traefik, or the ingress nginx-gw addon so that it can be exposed outside the cluster.

For example, the dashboard can be enabled along with ingress traefik addon using the following command:

```
k2s addons enable dashboard --ingress traefik
```

Similarly, the dashboard can be enabled along with ingress nginx-gw addon using the following command:

```
k2s addons enable dashboard --ingress nginx-gw
```

_Note:_ The above commands shall enable the respective ingress addon if it is not enabled.

## Accessing the dashboard

The dashboard UI can be accessed via the following methods.

### Access using ingress

To access dashboard via ingress, the ingress nginx, the ingress traefik, or the ingress nginx-gw addon has to be enabled.
Once the addons are enabled, the dashboard UI can be accessed at the following link: https://k2s.cluster.local/dashboard/

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the hosts **k2s.cluster.local** as a proxy override.

### Access using port-forwarding

To access dashboard via port-forwarding, the following command can be executed:

```
kubectl -n dashboard port-forward svc/kubernetes-dashboard 8443:443
```

In this case, the dashboard UI can be accessed at the following link: <https://localhost:8443>

_Note:_ It is not important to use port 8443 during port-forwarding. Any available port can be used.

### Login to dashboard

When the dashboard UI is opened in the browser, please press the **Skip** button. This allows the users to begin using the dashboard without generating the access token or using the KUBECONFIG file for login.

## Disable dashboard

The dashboard can be disabled using the k2s CLI by running the following command:

```
k2s addons disable dashboard
```

_Note:_ The above command will only disable dashboard addon. If other addons were enabled while enabling the dashboard addon, they will not be disabled.

## Further Reading

- Kubernetes Dashboard Docs on GitHub: <https://github.com/kubernetes/dashboard/tree/master/docs>-+-+-+-+-+
The dashboard addon supports integration with any of the following ingress controllers: nginx, traefik, or nginx-gw. This integration enables external cluster access to the dashboard.

Example command to enable the dashboard with traefik ingress:

```
k2s addons enable dashboard --ingress traefik
```

Example command to enable the dashboard with nginx-gw ingress:

```
k2s addons enable dashboard --ingress nginx-gw
```

_Note:_ If the specified ingress controller is not already active, it will be enabled automatically.

## Accessing the dashboard

Multiple access methods are available for the dashboard UI.

### Access using ingress

Accessing the dashboard through an ingress controller requires one of the supported addons (nginx, traefik, or nginx-gw) to be active.
After enabling the appropriate addon, navigate to: https://k2s.cluster.local/dashboard/

_Note:_ When using a proxy server configured in Windows Proxy settings, add **k2s.cluster.local** to the proxy bypass list.

### Access using port-forwarding

Execute the following command to access the dashboard through port-forwarding:

```
kubectl -n dashboard port-forward svc/kubernetes-dashboard 8443:443
```

Access the dashboard at: <https://localhost:8443>

_Note:_ Port 8443 is used as an example. You may substitute any available local port.

### Login to dashboard

Upon opening the dashboard in a browser, select the **Skip** option to proceed without token-based authentication or kubeconfig file login.

## Disable dashboard

Disable the dashboard addon with the following command:

```
k2s addons disable dashboard
```

_Note:_ This command affects only the dashboard addon. Any ingress or metrics addons enabled alongside the dashboard will remain active.

## Further Reading

- Kubernetes Dashboard Docs on GitHub: <https://github.com/kubernetes/dashboard/tree/master/docs>

