<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# Addon - Metrics Server

## Introduction

Metrics Server is a scalable, efficient source of container resource metrics for Kubernetes
built-in autoscaling pipelines.

Metrics Server collects resource metrics from Kubelets and exposes them in Kubernetes apiserver through [Metrics API]. Metrics API can also be accessed by `kubectl top`,
making it easier to debug autoscaling pipelines.

[Metrics API]: https://github.com/kubernetes/metrics

## Getting started

The metrics server addon can be enabled by runing the following command:
```
k2s addons enable metrics-server
```

## Disable metrics server

The metrics server addon can be disabled by running the following comannd:
```
k2s addons disable metrics-server
```

## Further Reading 

- [Kubernetes Metrics Server](https://github.com/kubernetes-sigs/metrics-server/blob/master/README.md)