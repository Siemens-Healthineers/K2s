<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# *K2s* Addons
*K2s* provides a rich set of addons that offer optional, pre-configured 3rd-party open-source OTS in a plugin-like manner for rapid prototyping, testing and OTS evaluation. They can also be used in product scenarios, check yourself if they fit well to your needs.

<span style="color:orange;font-size:medium">**⚠** </span> The 3rd-party software versions and configurations provided by these addons are partially taken from other open source projects. Please check yourself if these configurations are appropriate.

## Addons List
The following addons will be deployed with **K2s**:

<!-- GENERATED! Use the script Update-Readme.ps1 to update the following section -->
<!-- addons-list-start -->
|Addon|Description|
|---|---|
| [autoscaling](./autoscaling/README.md) | Horizontally scale workloads based on external events or triggers with KEDA (Kubernetes Event-Driven Autoscaling) | 
| [dashboard](./dashboard/README.md) | Dashboard for Kubernetes | 
| [exthttpaccess](./exthttpaccess/README.md) | Expose the K2s cluster via HTTP/HTTPS outside the host machine boundary. | 
| [gateway-api](./gateway-api/README.md) | Manage ingress traffic and routing for services within a cluster using Gateway API resource | 
| [gpu-node](./gpu-node/README.md) | Configure the control plane node to utilize GPUs for direct GPU access and high-performance computing tasks. | 
| [ingress nginx](./ingress/nginx/README.md) | Ingress Controller for external access that uses nginx as a reverse proxy | 
| [ingress traefik](./ingress/traefik/README.md) | Ingress Controller for external access that uses traefik as a reverse proxy | 
| [kubevirt](./kubevirt/README.md) | Manage VM workloads with k2s | 
| [logging](./logging/README.md) | Dashboard for Kubernetes container logs | 
| [metrics](./metrics/README.md) | Kubernetes metrics server for API Access to service metrics | 
| [monitoring](./monitoring/README.md) | Dashboard for cluster resource monitoring and logging | 
| [registry](./registry/README.md) | Private image registry running in the Kubernetes cluster exposed on k2s-registry.local | 
| [rollout](./rollout/README.md) | Automating the deployment/updating of applications | 
| [security](./security/README.md) | EXPERIMENTAL: Enables secure communication into and inside the cluster | 
| [storage smb](./storage/smb/README.md) | StorageClass provisioning based on SMB share between K8s nodes (Windows/Linux) | 
<!-- addons-list-end -->

## Command line options

On command line you can get all the addons available in your setup:
```
k2s addons ls                                         - lists all the available addons
```
Enabling one addon (in this example the **ingress** addon with **nginx** implementation):
```
k2s addons enable ingress nginx                       - enables the ingress nginx ingress controller
```
Disabling the same addon:
```
k2s addons disable ingress nginx                      - disables the ingress nginx ingress controller
```
Exporting addons for the offline usage afterwards:
```
k2s addons export -d d:\                              - exports all addons to a specfic location 
k2s addons export "ingress nginx" -d d:\              - exports implementation 'nginx' of addon 'ingress' to a specfic location 
k2s addons export ingress -d d:\                      - exports all implementations of addon 'ingress' to a specfic location 
```
Importing all addons from an previously exported file:
```
k2s addons import -z d:\addons.zip                    - imports all addons for offline usage 
k2s addons import "ingress nginx" -z d:\addons.zip    - imports implementation 'nginx' of addon 'ingress' from zip 
k2s addons import ingress -z d:\addons.zip            - imports all implementations of addon 'ingress' from zip 
```
Showing status of single addons:
```
k2s addons status ingress nginx                       - shows the status of the implementation 'ngnix' of addon 'ingress'
```

## Contributing
To add a new addon to this repo, the following steps are necessary:
1. create a **new addon folder** next to the [existing addon folders](./)
2. create a **addon.manifest.yaml** inside that folder containing at least the mandatory addon metadata
   - this metadata must comply with the [addon.manifest.schema.json](addon.manifest.schema.json) file
   - this metadata gets validated against the [addon.manifest.schema.json](addon.manifest.schema.json) file when addon-related commands are executed via *K2s.exe*, e.g. `k2s addons ls` or even `k2s addons -h`
   - refer to existing addon manifests for examples, e.g. [dashboard addon manifest](./dashboard/addon.manifest.yaml) or [ingress addon manifest](./ingress/addon.manifest.yaml)
   - the CLI flags and *PowerShell* parameters can differ in names (hence the parameter mapping config in the manifest file), but not in values, meaning e.g. if the CLI flag value for *SMB* host type is *windows*, it must be also *windows* for the *PowerShell* parameter value
   - for additional documentation on addons metadata refer to the [addon.manifest.schema.json](addon.manifest.schema.json) file
3. create mandatory ***PowerShell* scripts** (see existing addons) -> support import/export/upgrade, etc.
4. create mandatory **README.md** file
5. **run [Update-Readme.ps1](./Update-Readme.ps1)** to update [this list](#addons-list)
6. optional: add addon-specific code/config files
