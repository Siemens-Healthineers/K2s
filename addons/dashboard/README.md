<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

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

### Intergration with metrics-server addon

By enabling the metrics-server addon, the dashboard addon can present the collected metrics in the dashboard UI. 

The following commands enable the metrics-server addon and the dashboard addon:
```
k2s addons enable metrics-server
k2s addons enable dashboard
```

The metrics-server addon can be enabled while enabling the dashboard addon using the following command:
```
k2s addons enable dashboard --enable-metrics-server
```

### Integration with ingress-nginx and traefik addons

The dashboard addon can be integrated with either the ingress-nginx addon or the traefik addon so that it can be exposed outside the cluster.

For example, the dashboard can be enabled along with traefik addon using the following command:
```
k2s addons enable dashboard --ingress traefik
```
_Note:_ The above command shall enable the traefik addon if it is not enabled.

## Accessing the dashboard

The dashboard UI can be accessed via the following methods.

### Access using ingress

To access dashboard via ingress, the ingress-nginx or the traefik addon has to enabled.
Once the addons are enabled, then the dashboard UI can be accessed at the following link: https://k2s-dashboard.local

### Access using port-forwarding

To access dashboard via port-forwarding, the following command can be executed:
```
kubectl -n kubernetes-dashboard port-forward svc/kubernetes-dashboard 8443:443
```
In this case, the dashboard UI can be accessed at the following link: https://localhost:8443

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
- Kubernetes Dashboard Docs on GitHub: https://github.com/kubernetes/dashboard/tree/master/docs