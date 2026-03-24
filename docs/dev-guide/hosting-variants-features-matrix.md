<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Hosting Variants Features Matrix
See also [Hosting Variants](../user-guide/hosting-variants.md).

| Hosting Variant        | Host OS |   L2Bridge    |   DNSProxy    |   HttpProxy   |   VFPRules    |
| ---------------------- | :-----: | :-----------: | :-----------: | :-----------: | :-----------: |
| Host                   | Windows |   &#10004;    |   &#10004;    |   &#10004;    |   &#10004;    |
| Development-Only       | Windows |   &#10008;    |   &#10008;    |   &#10004;    |   &#10008;    |
| Linux-only             | Windows |   &#10008;    |   &#10008;    |   &#10008;    |   &#10008;    |
| Host (WSL)             | Windows |   &#10004;    |   &#10004;    |   &#10004;    |   &#10004;    |
| Development-Only (WSL) | Windows |   &#10008;    |   &#10008;    |   &#10004;    |   &#10008;    |
| Linux-only (WSL)       | Windows | not supported | not supported | not supported | not supported |
| Linux Host *(experimental)* | Linux   |   &#10008;    |   &#10008;    |   &#10008;    |   &#10008;    |

## *Linux Host*

!!! warning "Experimental"
    Linux host support is experimental. Some features may be incomplete or change without notice.

On a Linux host the control plane runs natively (no VM). An optional Windows VM is provisioned via libvirt/KVM for mixed-OS workloads. Networking uses standard Linux routing and iptables — L2Bridge, DNSProxy, VFPRules are Windows-specific components and are not used.

## *L2Bridge*
Creation of *L2Bridge* is essential for communication between *Pods* across *Linux* and *Windows* nodes. In principle, a network adapter named `cbr0` is created to facilitate communication across nodes.

## *DNSProxy*
Acts as internal DNS server on *Windows* node. Status can be checked with cmd `nssm status dnsproxy`.

## *HttpProxy*
Internal proxy running on *Windows* node. Status can be checked with cmd `nssm status httpproxy`.

In order to access resources on the internet the following proxy settings need to be used:

- *Host*: Proxy `http://172.19.1.1:8181` needs to be used inside *Linux* *Pods* and *Windows* *Pods*. The *Linux* node needs the proxy as well.
- *Linux-only*: No proxy needs to be used. Internet access is possible through NAT.

!!! example
    ```console
    curl www.example.com --proxy http://172.19.1.1:8181
    ```

## *VFPRules*
Dynamic rules added in `cbr0` switch for *Windows* containers networking.