<!--
SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH

SPDX-License-Identifier: MIT
-->

K2s Variant Features Overview
==============

| Variant           | L2Bridge       | DNSProxy       | HttpProxy      | VFPRules       |
|-------------------|:---------:     |:---------:     |:---------:     |:---------:     |
| host              | &#10004;       | &#10004;       | &#10004;       | &#10004;       |
| multi-vm          | &#10004;       | &#10008;       | &#10004;       | &#10004;       |
| build-only        | &#10008;       | &#10008;       | &#10004;       | &#10008;       |
| linux-only        | &#10008;       | &#10008;       | &#10008;       | &#10008;       |
| host (WSL)        | &#10004;       | &#10004;       | &#10004;       | &#10004;       |
| multi-vm (WSL)    | not supported  | not supported  | not supported  | not supported  |
| build-only (WSL)  | &#10008;       | &#10008;       | &#10004;       | &#10008;       |
| linux-only (WSL)  | not supported  | not supported  | not supported  | not supported  |

**L2Bridge**: Creation of L2Bridge is essential for communication between pods across linux and windows node. In principle, a network adapter named `cbr0` is created to facilitate communication across nodes.

**DNSProxy**: Acts as internal DNS server on windows node. Status can be checked with cmd `nssm status dnsproxy`.

**HttpProxy**: Internal Proxy running on windows node. Status can be checked with cmd `nssm status httpproxy`. 
In order to access resource on internet the following proxy settings needs to be used:
- **host**: Proxy `http://172.19.1.1:8181` needs to be used inside Linux pods and Windows pods. Linux node needs the proxy as well.
- **multi-vm**: Proxy `http://172.19.1.101:8181` needs to be used only inside Windows pods. Linux node and Windows node can reach internet through NAT directly as well as Linux Pods.
- **linux-only**: No proxy needs to be used. Internet access is possible through NAT.

**Example**: `` curl www.example.com --proxy http://172.19.1.1:8181`` 

**VFPRules**: Dynamic rules added in cbr0 switch for windows containers networking.