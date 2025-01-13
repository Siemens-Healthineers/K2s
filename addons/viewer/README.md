<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# viewer

## Introduction

The `viewer` addon provides a local Dicom images viewer based in the Ohif viewer running inside k2s.

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

The viewer can be accessed from an browser under the following url:
https://k2s.cluster.local/viewer/

## Disable viewer

The viewer addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable viewer
```

_Note:_ The above command will only disable viewer addon. If other addons were enabled while enabling the viewer addon, they will not be disabled.
