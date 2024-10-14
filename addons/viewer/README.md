<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# viewer

## Introduction

The `viewer` addon provides a local [Docker viewer](https://github.com/distribution/distribution) running inside k2s which makes it easy to store container images locally and pull them during deployment.

## Getting started

The viewer addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable viewer
```

### Integration with ingress nginx and ingress traefik addons

The viewer addon can be integrated with either the ingress nginx addon or the ingress traefik addon so that it can be exposed outside the cluster.

By default `k2s addons enable viewer` enables ingress nginx addon in a first step.

The viewer addon can also be enabled along with ingress traefik addon using the following command:
```
k2s addons enable viewer --ingress traefik
```
_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Access to viewer

### Ingress

In order to push container images to the local viewer during `k2s image build -p` by using an ingress tagging must look like the following:

```
k2s-viewer.local/<imagename>:<imagetag>
```

### NodePort

In order to push container images to the local viewer during `k2s image build -p` with node port configuration tagging must look like the following:

```
k2s-viewer.local:<nodeport>/<imagename>:<imagetag>
```

### viewer credentials

During enabling of the viewer addon the user is prompt to provide viewer credentials.

## Disable viewer

The viewer addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable viewer
```

_Note:_ The above command will only disable viewer addon. If other addons were enabled while enabling the viewer addon, they will not be disabled.

## Further Reading
- [Docker viewer](https://docs.docker.com/viewer/)
