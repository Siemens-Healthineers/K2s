<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Hosting Variants Features Matrix
See also [Hosting Variants](../user-guide/hosting-variants.md).

| Hosting Variant        |   L2Bridge    |   DNSProxy    |   HttpProxy   |   VFPRules    |
| ---------------------- | :-----------: | :-----------: | :-----------: | :-----------: |
| Host                   |   &#10004;    |   &#10004;    |   &#10004;    |   &#10004;    |
| Multi VM               |   &#10004;    |   &#10008;    |   &#10004;    |   &#10004;    |
| Development-Only       |   &#10008;    |   &#10008;    |   &#10004;    |   &#10008;    |
| Linux-only[^1]         |   &#10008;    |   &#10008;    |   &#10008;    |   &#10008;    |
| Host (WSL)             |   &#10004;    |   &#10004;    |   &#10004;    |   &#10004;    |
| Multi VM (WSL)         | not supported | not supported | not supported | not supported |
| Development-Only (WSL) |   &#10008;    |   &#10008;    |   &#10004;    |   &#10008;    |
| Linux-only[^1] (WSL)   | not supported | not supported | not supported | not supported |

[^1]: *Linux-only* is technically a *Multi VM* setup without a *Windows* worker VM and therefor not mentioned in [Hosting Variants](../user-guide/hosting-variants.md).

## *L2Bridge*
Creation of *L2Bridge* is essential for communication between *Pods* across *Linux* and *Windows* nodes. In principle, a network adapter named `cbr0` is created to facilitate communication across nodes.

## *DNSProxy*
Acts as internal DNS server on *Windows* node. Status can be checked with cmd `nssm status dnsproxy`.

## *HttpProxy*
Internal proxy running on *Windows* node. Status can be checked with cmd `nssm status httpproxy`.

In order to access resources on the internet the following proxy settings need to be used:

- *Host*: Proxy `http://172.19.1.1:8181` needs to be used inside *Linux* *Pods* and *Windows* *Pods*. The *Linux* node needs the proxy as well.
- *Multi VM*: Proxy `http://172.19.1.101:8181` needs to be used only inside *Windows* *Pods*. *Linux* and *Windows* nodes can reach the internet through NAT directly as well as *Linux* *Pods*.
- *Linux-only*: No proxy needs to be used. Internet access is possible through NAT.

!!! example
    ```console
    curl www.example.com --proxy http://172.19.1.1:8181
    ```

## *VFPRules*
Dynamic rules added in `cbr0` switch for *Windows* containers networking.