<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# registry

## Introduction

The `registry` addon provides a local [Docker registry](https://github.com/distribution/distribution) running inside k2s which makes it easy to store container images locally and pull them during deployment.

## Getting started

The registry addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable registry
```

### Integration with ingress nginx and ingress traefik addons

The registry addon can be integrated with either the ingress nginx addon or the ingress traefik addon so that it can be exposed outside the cluster.

By default `k2s addons enable registry` enables ingress nginx addon in a first step.

The registry addon can also be enabled along with ingress traefik addon using the following command:
```
k2s addons enable registry --ingress traefik
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Access to registry

### Ingress

In order to push container images to the local registry during `k2s image build -p` by using an ingress tagging must look like the following:

```
k2s.registry.local/<imagename>:<imagetag>
```

_Note:_ If a proxy server is configured in the Windows Proxy settings, please add the host **k2s-registry.local** as a proxy override.

### NodePort

In order to push container images to the local registry during `k2s image build -p` with node port configuration tagging must look like the following:

```
k2s.registry.local:<nodeport>/<imagename>:<imagetag>
```

### Registry credentials

During enabling of the registry addon the user is prompt to provide registry credentials.

## Disable registry

The registry addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable registry
```

_Note:_ The above command will only disable registry addon. If other addons were enabled while enabling the registry addon, they will not be disabled.

## Further Reading
- [Docker Registry](https://docs.docker.com/registry/)
