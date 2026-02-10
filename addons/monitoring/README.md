<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# monitoring

## Introduction

The `monitoring` addon provides a [Grafana web-based UI](https://github.com/grafana/grafana) for Kubernetes resource monitoring. It enables users to monitor cluster resources which are collected by Prometheus (e.g. node, pod and GPU resources). For this purpose, several predefined dashboards are provided.

## Grafana License Compliance

K2s is licensed under the MIT License.

It interacts with Grafana (AGPLv3) solely through its standard, public APIs; no AGPL‑licensed code is incorporated or modified, and Grafana is deployed as an container. For this integration scenario, a copyleft assessment was performed with the conclusion that AGPLv3 copyleft obligations are not triggered for this specific scenario.

**Important:** The AGPLv3 terms continue to apply to Grafana itself. Users must independently assess whether the AGPLv3 is appropriate for their use case.

## Getting started

The monitoring addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable monitoring
```

## Backup and restore

Create a backup zip (defaults to `C:\Temp\Addons` on Windows):
```
k2s addons backup monitoring
```

Restore from a backup zip:
```
k2s addons restore monitoring -f C:\Temp\Addons\monitoring_backup_YYYYMMDD_HHMMSS.zip
```

Notes:
- Backups are config-only (Kubernetes Secrets are not backed up or restored).
- Persistent volume data is not backed up or restored.
- Backups selectively capture user-relevant configuration (Grafana dashboards/datasources ConfigMaps, ingress objects, and non-Helm-managed Prometheus Operator custom resources).
- If no custom resources are present, the backup can be metadata-only (`files: []`); restore is then effectively a reinstall/repair.

During restore, Helm-managed resources (chart defaults) are skipped to avoid conflicts with the addon enable/reconcile process.

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

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the hosts **k2s.cluster.local** as a proxy override.

### Access using port-forwarding

To access monitoring dashboard via port-forwarding, the following command can be executed:

```
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
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
- [Grafana OSS](http://github.com/grafana/grafana)
