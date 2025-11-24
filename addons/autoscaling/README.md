<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# autoscaling

## Introduction

The `autoscaling` addon provides the possibility to horizontally scale workloads based on external events or triggers with [KEDA](https://github.com/kedacore/keda) (Kubernetes Event-Driven Autoscaling). 

KEDA serves as a Kubernetes Metrics Server and allows users to define autoscaling rules using a dedicated Kubernetes custom resource definition.

## Getting started

The autoscaling addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable autoscaling
```

## Scaling
KEDA supports a wide range of [scalers](https://keda.sh/docs/latest/scalers/) e.g. [CPU](https://keda.sh/docs/latest/scalers/cpu/) or [Memory](https://keda.sh/docs/latest/scalers/memory/). KEDA scalers can both detect if a deployment should be activated or deactivated, and feed custom metrics for a specific event source.

## Disable autoscaling

The autoscaling addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable autoscaling
```

## Further Reading 

- [KEDA](https://keda.sh/)
