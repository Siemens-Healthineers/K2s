<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
SPDX-License-Identifier: MIT
-->

# Check *K2s* Status
To check *K2s*'s health status (including *K8s*'s health), run:
```console
k2s status
```

To display additional status details, run:
```console
<repo>k2s status -o wide
```

<figure markdown="span">
  ![Status Command Output](assets/status_cmd_output.png){ loading=lazy }
  <figcaption>Output of "k2s status -o wide"</figcaption>
</figure>
