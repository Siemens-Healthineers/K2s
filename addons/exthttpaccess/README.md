<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG

SPDX-License-Identifier: MIT
-->

# exthttpaccess

## Introduction

The `exthttpaccess` addon provides an implementation of the [NGINX](https://nginx.org/) and acts as a reverse proxy. It handles HTTP/HTTPS requests coming to the Windows host machine from local or external networks. Thereby it is possible to reach cluster workloads via the ip address of the cluster host machine from another client. It can be also configured with a proxy.

## Getting started

The exthttpaccess addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable exthttpaccess
```

## Ports

The exthttpaccess addon uses standard HTTP/HTTPS ports `80/443`. If those ports are used by other processes the addon switches automatically to alternative ports `8080/8443`. Furthermore it is possible to specify custom HTTP/HTTPS ports.