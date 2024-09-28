<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# monitoring

## Introduction

The `monitoring` addon provides a [Grafana web-based UI](https://github.com/credativ/plutono) for Kubernetes resource monitoring. It enables users to monitor cluster resources which are collected by Prometheus e.g. node, pod and GPU resources. For this several predefined dashboards are provided.

## Getting started

The monitoring addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable monitoring
```

### Integration with ingress nginx and ingress traefik addons

The monitoring addon can be integrated with either the ingress nginx or the ingress traefik addon so that it can be exposed outside the cluster.

For example, the monitoring addon can be enabled along with traefik addon using the following command:

```
k2s addons enable monitoring --ingress traefik
```

_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Accessing the monitoring dashboard

The monitoring dashboard UI can be accessed via the following methods.

### Access using ingress

To access monitoring dashboard via ingress, the ingress nginx or the ingress traefik addon has to enabled.
Once the addons are enabled, then the monitoring dashboard UI can be accessed at the following URL: <https://k2s.cluster.local/monitoring>

### Access using port-forwarding

To access monitoring dashboard via port-forwarding, the following command can be executed:

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-plutono 3000:80
```

In this case, the monitoring dashboard UI can be accessed at the following URL: <http://localhost:3000/monitoring>

### Login to monitoring dashboard

When the monitoring dashboard UI is opened in the browser, please use the following credentials for initial login:

```
username: admin
password: admin
```

_Note:_ Credentials can be changed after first login.

## Disable monitoring

The monitoring addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable monitoring
```

_Note:_ The above command will only disable monitoring addon. If other addons were enabled while enabling the monitoring addon, they will not be disabled.

## Further Reading

- [Prometheus](https://prometheus.io/)
- [Plutono](https://github.com/credativ/plutono)
