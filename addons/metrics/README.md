<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# metrics

## Introduction

The `metrics` addon provides a metrics server which is a scalable, efficient source of container resource metrics for Kubernetes built-in autoscaling pipelines.

Metrics Server collects resource metrics from Kubelets and exposes them in Kubernetes apiserver through [Metrics API]. Metrics API can also be accessed by `kubectl top`,
making it easier to debug autoscaling pipelines.

[Metrics API]: https://github.com/kubernetes/metrics

## Getting started

The metrics server addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable metrics
```

## Further Reading 

- [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server/blob/master/README.md)