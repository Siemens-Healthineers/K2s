<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Assignment of Cluster IP Addresses for Services
## *Linux*-based workloads
In case of services on *Linux* side please use the subnet `172.21.0.0/24` starting from `172.21.0.50` (*K2s* reserves addresses up to `172.21.0.49`).

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
    name: Linux-example
    spec:
    selector:
        app: Linux-example
    ports:
        - protocol: TCP
        port: 80
        targetPort: 80
    clusterIP: 172.21.0.210
    ```

## *Windows*-based workloads
In case of services on *Windows* side please use the subnet `172.21.1.0/24` starting from `172.21.1.50` (*K2s* reserves addresses up to `172.21.1.49`).

!!! example
    ```yaml linenums="1" title="example-service-manifest.yaml"
    apiVersion: v1
    kind: Service
    metadata:
    name: Windows-example
    spec:
    selector:
        app: Windows-example
    ports:
        - protocol: TCP
        port: 80
        targetPort: 80
    clusterIP: 172.21.1.210
    ```