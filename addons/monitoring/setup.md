<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Kube-Prometheus-Stack
## Generate manifests
1. helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
2. helm repo update
3. helm fetch prometheus-community/kube-prometheus-stack --untar
4. mkdir output\kube-prometheus-stack\crds
5. helm template -n monitoring kube-prometheus-stack . --output-dir .\output --include-crds --debug --skip-tests
6. Merge manifests under output\kube-prometheus-stack to existing structure like in addons/monitoring/manifests
7. Copy and overide manifests to addons/monitoring/manifests
8. Update kustomization.yaml

## Keep following files
- grafana/ingress.yaml
- grafana/traefik.yaml
- grafana/dashboards-1.14/gpu.yaml
- grafana/dashboards-1.14/windows-node-1.yaml
- grafana/dashboards-1.14/windows-node-2.yaml
- grafana/configmaps-datasources.yaml
- prometheus/additionalScrapeConfigs.yaml

## Modify following files
- grafana/configmap.yaml:

```
    [server]
    # these settings needed to make it work with Ingress
    root_url = http://k2s-monitoring.local
    domain: k2s-monitoring.local

```

- grafana/secret.yaml
```
  admin-user: "YWRtaW4=" #admin
  admin-password: "YWRtaW4=" #admin
```

- prometheus/prometheus.yaml

```
  additionalScrapeConfigs:
    name: kube-prometheus-stack-prometheus-scrape-confg
    key: additional-scrape-configs.yaml
```

# Apache 2.0 License fulfilments

Grafana changed their license model to AGPL-3.0 license. In order to use sources still under Apache 2.0 license the following Github forks are used:

- https://github.com/credativ/plutono (Plutono is a fork of Grafana 7.5.17 under the Apache 2.0 License.)

Follow replacement steps under 'About this fork'.