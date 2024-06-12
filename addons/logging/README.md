<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

# logging

## Introduction

The `logging` addon provides a [Kibana web-based UI](https://github.com/opensearch-project/OpenSearch-Dashboards) for Kubernetes logging. It enables users to analyze container logs from k2s cluster supporting full-text search.

## Getting started

The logging addon can be enabled using the k2s CLI by running the following command:
```
k2s addons enable logging
```

### Integration with ingress-nginx and traefik addons

The logging addon can be integrated with either the ingress-nginx addon or the traefik addon so that it can be exposed outside the cluster.

For example, the logging addon can be enabled along with traefik addon using the following command:
```
k2s addons enable logging --ingress traefik
```
_Note:_ The above command shall enable the traefik addon if it is not enabled.

## Accessing the logging dashboard

The logging dashboard UI can be accessed via the following methods.

### Access using ingress

To access logging dashboard via ingress, the ingress-nginx or the traefik addon has to enabled.
Once the addons are enabled, then the logging dashboard UI can be accessed at the following link: https://k2s.cluster.local/logging/ and https://k2s-logging.local (with HTTP using http://.. unstead of https://..)

### Access using port-forwarding

To access logging dashboard via port-forwarding, the following command can be executed:
```
kubectl -n logging port-forward svc/opensearch-dashboards 5601:5601
```
In this case, the logging dashboard UI can be accessed at the following link: http://localhost:5601

Once the `Home` section appears, navigate to `Menu -> Discover`. Now logs can be searched and analyzed.

## OpenTelemetry

The OpenTelemetry input plugin of the logging addon allows receiving data as per the OTLP specification. The following endpoint can be used to send logs to the logging addon:

```
http://otel.logging.svc.cluster.local:4318/v1/logs
```

Those logs are added to the same index like all other logs and are visible under the `Discover` section.

## Disable logging

The logging addon can be disabled using the k2s CLI by running the following command:
```
k2s addons disable logging
```

_Note:_ The above command will only disable logging addon. If other addons were enabled while enabling the logging addon, they will not be disabled.

## Further Reading
- [fluentbit](https://github.com/fluent/fluent-bit)
- [opensearch](https://github.com/opensearch-project/OpenSearch)
