<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Hosting Variants
## Host (Default)
On the *Windows* host, a single VM is exclusively utilized as the *Linux* control-plane node while the *Windows* host itself functions as the worker node.

This variant is also the default, offering efficient and very low memory consumption. The VM's memory usage starts at 2GB.<br/><br/>
![Host Variant](assets/VariantHost400.jpg)

## Development-Only
In this variant, the focus is on setting up an environment solely for building and testing *Windows* and *Linux* containers without creating a *K8s* cluster.<br/><br/>
![Development-Only](assets/VariantDevOnly400.jpg)
