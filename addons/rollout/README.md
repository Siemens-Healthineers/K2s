<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Rollout

## Introduction

The `rollout` addon provides a way to automate the deployment of applications. It uses ArgoCD under the hood. It automates the deployment of applications by continuously monitoring the live state of applications and comparing it to the desired state defined in a Git repository. New deployments can be created via a CLI or the [ArgoCD web-based UI](https://argo-cd.readthedocs.io/en/stable/getting_started/#creating-apps-via-ui)

## Getting started

The rollout addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable rollout
```

### Integration with ingress nginx and ingress traefik addons

The rollout addon can be integrated with either the ingress nginx or the ingress traefik addon so that it can be exposed outside the cluster.

For example, the rollout addon can be enabled along with traefik addon using the following command:
```
k2s addons enable rollout --ingress traefik
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Accessing the rollout dashboard

The rollout dashboard can be accessed via the following methods.

### Access using ingress

To access the rollout dashboard via ingress, the ingress nginx or the ingress traefik addon has to be enabled.
Once the addons are enabled, then the rollout dashboard can be accessed at the following URL: <https://k2s.cluster.local/rollout>

### Access using port-forwarding

To access the rollout dashboard via port-forwarding, the following command can be executed:
```
kubectl -n rollout port-forward svc/argocd-server 8080:443
```
In this case, the rollout dashboard UI can be accessed at the following URL: <https://localhost:8080/rollout>

### Deploy an application with the rollout addon

There are two ways of deploying applications with the rollout addon, either by using the CLI or web UI:

#### Via CLI

Step 1 - Login via the CLI:
```
argocd login k2s.cluster.local:443 --grpc-web-root-path "rollout"
```
Proceed with the username and the password returend by the enable process.

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
The reason for this is the scoped installtion of ArgoCD to the `rollout` namespace.

To import:
```
 Get-Content -Raw .\backup.yaml | argocd admin import -n rollout -
```


## Further Reading
- [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)