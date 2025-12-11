<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Rollout - Flux CD Implementation

## Introduction

Flux CD is a GitOps tool that automatically syncs Kubernetes cluster state with Git repositories. Unlike ArgoCD, Flux has **no web UI** and is managed entirely via CLI and YAML manifests.

## Enable Flux

```powershell
k2s addons enable rollout fluxcd
```

### Optional: Enable Webhooks (for Git push notifications)

```powershell
k2s addons enable rollout fluxcd --ingress nginx
```

Most users don't need this—Flux polls Git by default (every 1 minute).

## Check Status

```powershell
k2s addons status rollout fluxcd
```

## Deploy Application with Flux

### 1. Create GitRepository

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 1m
  url: https://github.com/myorg/myapp
  ref:
    branch: main
```

### 2. Create Kustomization

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
  namespace: rollout
spec:
  interval: 5m
  sourceRef:
    kind: GitRepository
    name: myapp
  path: ./deploy
  prune: true
  targetNamespace: default
```

### 3. Apply

```powershell
kubectl apply -f gitrepository.yaml
kubectl apply -f kustomization.yaml
```

Flux will now sync your app from Git every 5 minutes.

## Deploy Helm Charts

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: HelmRepository
metadata:
  name: bitnami
  namespace: rollout
spec:
  interval: 1h
  url: https://charts.bitnami.com/bitnami
---
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: nginx
  namespace: default
spec:
  interval: 5m
  chart:
    spec:
      chart: nginx
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: rollout
  values:
    replicaCount: 2
```

## Disable Flux

```powershell
k2s addons disable rollout fluxcd
```

## Learn More

- [Flux Documentation](https://fluxcd.io/docs/)
- [Flux Guides](https://fluxcd.io/flux/guides/)
