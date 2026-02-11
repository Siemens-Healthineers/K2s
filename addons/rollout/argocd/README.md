<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# Rollout - ArgoCD Implementation

## Introduction

This is the ArgoCD implementation of the rollout addon. ArgoCD is a declarative, GitOps continuous delivery tool for Kubernetes that automates the deployment of applications by continuously monitoring the live state of applications and comparing it to the desired state defined in a Git repository. New deployments can be created via a CLI or the [ArgoCD web-based UI](https://argo-cd.readthedocs.io/en/stable/getting_started/#creating-apps-via-ui)

## Getting started

The rollout addon with ArgoCD implementation can be enabled using the k2s CLI by running the following command:
```
k2s addons enable rollout
```

### Integration with ingress nginx and ingress traefik addons

The ArgoCD dashboard can be integrated with the ingress nginx, ingress nginx-gw, or ingress traefik addon so that it can be exposed outside the cluster.

For example, the rollout addon can be enabled along with traefik addon using the following command:
```
k2s addons enable rollout --ingress traefik
```

Or with nginx-gw addon using the following command:
```
k2s addons enable rollout --ingress nginx-gw
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Accessing the ArgoCD dashboard

The ArgoCD dashboard can be accessed via the following methods.

### Access using ingress

To access the ArgoCD dashboard via ingress, the ingress nginx, ingress nginx-gw, or ingress traefik addon has to be enabled.
Once the addons are enabled, then the ArgoCD dashboard can be accessed at the following URL: <https://k2s.cluster.local/rollout>

### Access using port-forwarding

To access the ArgoCD dashboard via port-forwarding, the following command can be executed:
```
kubectl -n rollout port-forward svc/argocd-server 8080:443
```
In this case, the ArgoCD dashboard UI can be accessed at the following URL: <https://localhost:8080/rollout>

### Deploy an application with ArgoCD

There are two ways of deploying applications with ArgoCD, either by using the CLI or web UI:

#### Via CLI

Step 1 - Login via the CLI:
```
argocd login k2s.cluster.local:443 --grpc-web-root-path "rollout"
```
Proceed with the username and the password returned by the enable process.

Step 2 - Add a repository 
```
argocd repo add https://github.com/argoproj/argocd-example-apps.git
```
Here we add a Git repository where our configurations files are located. If the repository is private we can still access it by providing the corresponding credentials with `--username <username> --password <password>`.

Step 3 - Deploy example application
```
argocd app create guestbook --repo https://github.com/argoproj/argocd-example-apps.git --path guestbook --dest-server https://kubernetes.default.svc --dest-namespace argocd-test
```

Step 4 - Sync application
After creating an application with ArgoCD (Step 3), the application is not directly deployed in the cluster and has to be synced:
```
argocd app sync guestbook
```

#### Via the web UI

Step 1 - Login via the UI
Visit `k2s.cluster.local/rollout` and login using the credentials return by the enable process.

Step 2 - Add a repository
Navigate to Settings -> Repository -> Connect Repo

Fill in the information required information. If the repository is private, either provide your username and password or use the specific keys.

Step 3 - Deploy example application
Navigate to Applications -> New App 

Fill in the required information and create the app in ArgoCD

Step 4 - Sync application

In the application overview there should now be the option to sync your application.

## Disable rollout

The rollout addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable rollout
```

_Note:_ The above command will only disable rollout addon. If other addons were enabled while enabling the rollout addon, they will not be disabled.

## Further Information

If you want to use `argocd admin export` and `argocd admin import` you have to specific the `rollout` namespace: e.g. `argocd admin export -n rollout > backup.yaml`.
The reason for this is the scoped installation of ArgoCD to the `rollout` namespace.

To import:
```
 Get-Content -Raw .\backup.yaml | argocd admin import -n rollout -
```

## Backup and restore

Backup/restore is **scoped to the `rollout` namespace only**.

### What gets backed up

- `argocd admin export -n rollout` output (applications, projects, repo connections, settings stored in ArgoCD)
- Optional dashboard exposure resources in namespace `rollout` (if present):
	- `Ingress/rollout-nginx-cluster-local`
	- `Ingress/rollout-traefik-cluster-local`
	- `Middleware/oauth2-proxy-auth` (Traefik secure mode)

_Note:_ The ArgoCD export contains credentials (e.g., repository credentials). Handle the backup archive accordingly.

### What does not get backed up

- ArgoCD controller manifests/CRDs (they are re-installed during restore via `k2s addons enable rollout argocd`)
- Resources outside of the `rollout` namespace

### Commands

```console
k2s addons backup rollout argocd
k2s addons restore rollout argocd <path-to-backup-zip>
```


## Further Reading
- [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)