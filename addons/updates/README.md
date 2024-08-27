<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Updates

## Introduction

The `updates` addon provides a way to automate the deployment of applications. It uses ArgoCD under the hood. It automates the deployment of applications by continuously monitoring the live state of applications and comparing it to the desired state defined in a Git repository. New deployments can be created via a CLI or the [ArgoCD web-based UI](https://argo-cd.readthedocs.io/en/stable/getting_started/#creating-apps-via-ui)

## Getting started

The updates addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable updates
```

### Integration with ingress nginx and ingress traefik addons

The updates addon can be integrated with either the ingress nginx or the ingress traefik addon so that it can be exposed outside the cluster.

For example, the updates addon can be enabled along with traefik addon using the following command:
```
k2s addons enable updates --ingress traefik
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Accessing the updates dashboard

The updates dashboard UI can be accessed via the following methods.

### Access using ingress

To access updates dashboard via ingress, the ingress nginx or the ingress traefik addon has to enabled.
Once the addons are enabled, then the ArgoCD dashboard UI can be accessed at the following link: https://k2s.cluster.local/updates/ and https://k2s-updates.cluster.local/ (with HTTP using http://.. instead of https://..)

_Note:_ If the login doesn't work for https://k2s-updates.cluster.local/, please wait a little bit after enabling the addon and restart your browser or use an ingoknito tab to access the UI.  

### Access using port-forwarding

To access updates dashboard via port-forwarding, the following command can be executed:
```
kubectl -n updates port-forward svc/argocd-server 8080:443
```
In this case, the updates dashboard UI can be accessed at the following link: http://localhost:8080/

### Deploy an application with the updates addon

There are two ways of deploying applications with the updates addon, either by using the CLI or web UI:

#### Via CLI

Step 1 - Login via the CLI:
```
argocd login k2s.cluster.local:443 --grpc-web-root-path "updates"
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
Visit `k2s-updates.cluster.local` and login using the credentials return by the enable process.

Step 2 - Add a repository
Navigate to Settings -> Repository -> Connect Repo

Fill in the information required information. If the repository is private, either provide your username and password or use the specific keys.

Step 3 - Deploy example application
Navigate to Applications -> New App 

Fill in the required information and create the app in ArgoCD

Step 4 - Sync application

In the application overview there should now be the option to sync your application.

## Disable updates

The updates addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable updates
```

_Note:_ The above command will only disable updates addon. If other addons were enabled while enabling the updates addon, they will not be disabled.

## Further Information

If you want to use `argocd admin export` and `argocd admin import` you have to specific the `updates` namespace: e.g. `argocd admin export -n updates > backup.yaml`.
The reason for this is the scoped installtion of ArgoCD to the `updates` namespace.

To import:
```
 Get-Content -Raw .\backup.yaml | argocd admin import -n updates -
```


## Further Reading
- [ArgoCD](https://argo-cd.readthedocs.io/en/stable/)