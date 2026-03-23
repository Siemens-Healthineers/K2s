<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Overview
This folder contains all re-usable *Go* packages that cannot be referenced from outside this repo.

Even though they have interdependencies, the aim is to keep their coupling as low as possible.

As of now, the packages with higher levels of abstraction containing the domain logic are contained in the `core` folder.

## Key Packages

| Package | Purpose |
|---------|---------|
| `core/` | Domain logic: addons, cluster config, user management |
| `provider/` | **Platform-agnostic provider interfaces** and build-tagged implementations for Windows and Linux. Commands use these interfaces exclusively — see [provider/README.md](provider/README.md). |
| `powershell/` | Go ↔ PowerShell bridge (`ExecutePsWithStructuredResult`) |
| `setuporchestration/` | Linux-native cluster provisioning (kubeadm, libvirt/KVM, SSH) |
| `providers/` | Kubernetes, SSH, kubectl, kubeconfig utility providers |
| `containernetworking/` | Windows CNI bridge plugin logic |
| `cli/` | Exit codes, command helpers |
| `host/` | Host OS detection and operations |
| `os/` | OS-level utilities, `StdWriter` interface |

## Dependency Analysis

The dependencies can be analyzed with *Go* tooling, e.g.:

- Install [*Goda*](https://github.com/loov/goda):
    ```sh
    go install github.com/loov/goda@latest
    ```
- Install [*Graphviz*](https://graphviz.org/download/#windows)
- Generate graph:
    ```sh
    goda graph github.com/siemens-healthineers/k2s/internal/... | dot -Tsvg -o graph-internal.svg
    ```
