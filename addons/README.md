<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# *K2s* Addons
*K2s* provides a rich set of addons that offer optional, pre-configured 3rd-party open-source OTS in a plugin-like manner for rapid prototyping, testing and OTS evaluation. 

<span style="color:orange;font-size:medium">**⚠** </span> The 3rd-party software versions and configurations provided by these addons are not necessarily stable enough for production scenarios.

## Addons List
The following addons currently exist:

<!-- GENERATED! Use the script Update-Readme.ps1 to update the following section -->
<!-- addons-list-start -->
|Addon|Description|
|---|---|
| [dashboard](./dashboard/README.md) | Dashboard for Kubernetes | 
| [exthttpaccess](./exthttpaccess/README.md) | Handle HTTP/HTTPS request coming to windows machine from local or external network | 
| [gateway-nginx](./gateway-nginx/README.md) | EXPERIMENTAL USE: Gateway Controller for external access that provides an implementation of the Gateway API | 
| [gpu-node](./gpu-node/README.md) | Configure KubeMaster as GPU node for direct GPU access | 
| [ingress-nginx](./ingress-nginx/README.md) | Ingress Controller for external access that uses nginx as a reverse proxy | 
| [kubevirt](./kubevirt/README.md) | Manage VM workloads with k2s | 
| [metrics-server](./metrics-server/README.md) | Kubernetes metrics server for API Access to service metrics | 
| [monitoring](./monitoring/README.md) | Dashboard for cluster resource monitoring and logging | 
| [registry](./registry/README.md) | Private image registry running in the Kubernetes cluster exposed on k2s-registry.local | 
| [smb-share](./smb-share/README.md) | StorageClass provisioning based on SMB share between K8s nodes (Windows/Linux) | 
| [traefik](./traefik/README.md) | Ingress Controller for external access that uses traefik as a reverse proxy | 
<!-- addons-list-end -->

## Contributing
To add a new addon to this repo, the following steps are necessary:
1. create a **new addon folder** next to the [existing addon folders](./)
2. create a **addon.manifest.yaml** inside that folder containing at least the mandatory addon metadata
   - this metadata must comply with the [addon.manifest.schema.json](addon.manifest.schema.json) file
   - this metadata gets validated against the [addon.manifest.schema.json](addon.manifest.schema.json) file when addon-related commands are executed via *K2s.exe*, e.g. `k2s addons ls` or even `k2s addons -h`
   - refer to existing addon manifests for examples, e.g. [registry addon manifest](./registry/addon.manifest.yaml)
   - the CLI flags and *PowerShell* parameters can differ in names (hence the parameter mapping config in the manifest file), but not in values, meaning e.g. if the CLI flag value for *SMB* host type is *windows*, it must be also *windows* for the *PowerShell* parameter value
   - for additional documentation on addons metadata refer to the [addon.manifest.schema.json](addon.manifest.schema.json) file
3. create mandatory ***PowerShell* scripts** (see existing addons) -> support import/export/upgrade, etc.
4. create mandatory **README.md** file
5. **run [Update-Readme.ps1](./Update-Readme.ps1)** to update [this list](#addons-list)
6. optional: add addon-specific code/config files
