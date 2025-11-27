# Rollout - Flux CD Implementation

## Introduction

This is the Flux CD implementation of the rollout addon. Flux is a declarative, GitOps continuous delivery tool for Kubernetes that automatically synchronizes cluster state with Git repositories. Unlike ArgoCD, Flux has **no built-in UI** and is designed to be managed entirely through CLI and YAML manifests.

## Getting started

The rollout addon with Flux implementation can be enabled using the k2s CLI:
```
k2s addons enable rollout fluxcd
```

### Integration with ingress nginx and ingress traefik addons

Flux does not require ingress as it has no web UI. However, if you plan to use webhooks for Git notifications, you can enable ingress:

```
k2s addons enable rollout fluxcd --ingress nginx
```
_Note:_ The above command will enable the ingress nginx addon if not already enabled.

## Monitoring Flux Status

Since Flux has no UI, use these CLI commands to monitor your deployments:

### Check Flux controller status

```powershell
# Using k2s CLI
k2s addons status rollout fluxcd

# Using kubectl
kubectl get deployments -n rollout
kubectl get pods -n rollout
```

### Check Flux resources

```powershell
# List all GitRepository sources
kubectl get gitrepositories -A

# List all Kustomizations
kubectl get kustomizations -A

# List all HelmReleases
kubectl get helmreleases -A
```

### View controller logs

```powershell
kubectl logs -n rollout deployment/source-controller
kubectl logs -n rollout deployment/kustomize-controller
kubectl logs -n rollout deployment/helm-controller
kubectl logs -n rollout deployment/notification-controller
```

## Using Flux for GitOps

Flux uses Custom Resources to define what to sync from Git:

### Deploy an application with Flux

#### Step 1 - Create a GitRepository source

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

#### Step 2 - Create a Kustomization to deploy

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

#### Step 3 - Apply the resources

```bash
kubectl apply -f gitrepository.yaml
kubectl apply -f kustomization.yaml
```

Flux will automatically:
- Clone the Git repository
- Apply manifests from the `./deploy` path
- Continuously sync every 5 minutes
- Prune resources removed from Git

### Using Helm with Flux

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

## Key Differences from ArgoCD

- **No UI**: Flux is CLI/YAML-only; all operations done via kubectl
- **Fully automated**: No manual sync button, always auto-syncs from Git
- **Image automation**: Built-in image scanning and auto-update capabilities
- **Lightweight**: Smaller footprint with fewer components
- **Git-native**: All configuration defined via CRDs stored in Git
- **Monitoring**: Use CLI commands and logs instead of web dashboard

## Disable rollout

```
k2s addons disable rollout fluxcd
```

_Note:_ This only disables the Flux addon. Other addons enabled during installation remain enabled.

## Further Reading
- [Flux CD Documentation](https://fluxcd.io/docs/)
- [Flux Guides](https://fluxcd.io/flux/guides/)
- [Weave GitOps](https://docs.gitops.weave.works/)
