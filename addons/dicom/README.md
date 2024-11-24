<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# monitoring

## Introduction

The `dicom` addon provides a [Orthanc UI] for dicom server. It is designed to store, manage, and share medical images and related data. It provides a REST API for easy integration with other systems and supports various DICOM operations such as querying, retrieving, and storing medical images. 

## Getting started

The dicom addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable dicom
```

### Integration with ingress nginx and ingress traefik addons

The dicom addon can be integrated with either the ingress nginx or the ingress traefik addon so that it can be exposed outside the cluster.

For example, the dicom addon can be enabled along with traefik addon using the following command:

```
k2s addons enable dicom --ingress traefik
```

_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

## Accessing the dicom UI

The dicom UI can be accessed via the following methods.

### Access using ingress

To access dicom UI via ingress, the ingress nginx or the ingress traefik addon has to enabled.
Once the addons are enabled, then the dicom UI can be accessed at the following URL: <https://k2s.cluster.local/dicom>

### Access using port-forwarding

To access dicom server UI via port-forwarding, the following command can be executed:

```
kubectl -n dicom port-forward svc/orthanc 8042:80
```

In this case, the dicom UI can be accessed at the following URL: <http://localhost:8042/dicom>

## Disable dicom

The dicom addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable dicom
```

_Note:_ The above command will only disable dicom addon. If other addons were enabled while enabling the dicom addon, they will not be disabled.

## Further Reading

- [Orthanc](https://www.orthanc-server.com/)
