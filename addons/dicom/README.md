<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# monitoring

## Introduction

The `dicom` addon provides a full fledged DICOM server, which offers besides classic DICOM DIMSE services also DICOM Web APis through REST. 

It is designed to store, manage, and share medical images and related data. It provides a REST API for easy integration with other systems and supports various DICOM operations such as querying, retrieving, and storing medical images. 

In addition this addon also offers a very simple web app, which offers the possibility to interact with the dicom server. 

## Getting started

The dicom addon can be enabled using the k2s CLI by running the following command:

```
k2s addons enable dicom
```

### Integration with the ingress addon

The dicom addon can be integrated with either the ingress nginx or the ingress traefik addon so that it can be exposed outside the cluster.

For example, the dicom addon can be enabled along with traefik addon using the following command:

```
k2s addons enable dicom --ingress traefik
```

_Note:_ The above command shall enable the ingress traefik addon if it is not enabled.

The ingress addon can also be enabled before or after enabling the dicom addon, the effect would be the same !

## Accessing the dicom services

Per default we use port 4242 for the DIMSE classic communication and port 8042 for the DICOM web communication.

## Accessing the dicom UI

The dicom UI can be accessed via the following methods.

### Access directly to pod


### Access using port-forwarding

To access dicom server UI via port-forwarding, the following command can be executed:

```
kubectl -n dicom port-forward svc/dicom 8042:8042
```

In this case, the dicom UI can be accessed at the following URL: <http://localhost:8042/ui/app/>

### Access using ingress

To access the dicom app UI via ingress, the ingress nginx or the ingress traefik addon has to enabled.
Once the addons are enabled, then the dicom UI can be accessed at the following URL: <http://k2s.cluster.local/dicom/ui/app/>

## Disable dicom

The dicom addon can be disabled using the k2s CLI by running the following command:

```
k2s addons disable dicom
```

_Note:_ The above command will only disable dicom addon. If other addons were enabled while enabling the dicom addon, they will not be disabled.

## Further Reading

Internally used open source component:
- [Orthanc](https://www.orthanc-server.com/)
