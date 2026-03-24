<!--
SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Architecture & Tools

This page describes the high-level architecture of a *K2s* cluster, the supporting tools bundled with the distribution, and the internal module structure.

## High-Level Architecture

*K2s* supports two host configurations: a **Windows host** (the original and default) and a **Linux host** (inverted setup). Both produce a mixed-OS Kubernetes cluster with a Linux control plane and an optional worker node of the opposite OS.

### Windows Host (Default)

A single Windows machine runs the CLI, PowerShell modules, and a Linux VM as the Kubernetes control plane:

```
┌─────────────────────────────────────────────────────────┐
│  Windows Host                                           │
│                                                         │
│  ┌──────────────────┐    ┌───────────────────────────┐  │
│  │ Windows Worker   │    │ Linux VM (KubeMaster)     │  │
│  │                  │    │                           │  │
│  │ • containerd     │    │ • CRI-O                   │  │
│  │ • kubelet        │    │ • kubelet                 │  │
│  │ • kube-proxy     │    │ • kube-apiserver          │  │
│  │ • flannel (CNI)  │    │ • kube-scheduler          │  │
│  │ • Docker (opt.)  │    │ • kube-controller-manager │  │
│  │                  │    │ • etcd                    │  │
│  └──────────────────┘    │ • flannel (CNI)           │  │
│                          │ • CoreDNS                 │  │
│  k2s.exe CLI             │ • buildah                 │  │
│  httpproxy.exe           └───────────────────────────┘  │
│  PowerShell modules                                     │
│                                                         │
│  ─── Hyper-V / WSL 2 ────────────────────────────────── │
└─────────────────────────────────────────────────────────┘
```

### Linux Host (Inverted Setup)

A Linux machine runs the CLI natively, hosts the Kubernetes control plane directly, and provisions a Windows VM as an optional worker node:

```
┌─────────────────────────────────────────────────────────┐
│  Linux Host                                             │
│                                                         │
│  ┌───────────────────────┐    ┌──────────────────────┐  │
│  │ Linux Control Plane   │    │ Windows VM (Worker)  │  │
│  │                       │    │                      │  │
│  │ • CRI-O / containerd  │    │ • containerd         │  │
│  │ • kubelet             │    │ • kubelet            │  │
│  │ • kube-apiserver      │    │ • kube-proxy         │  │
│  │ • kube-scheduler      │    │ • flannel (CNI)      │  │
│  │ • kube-controller-mgr │    │                      │  │
│  │ • etcd                │    └──────────────────────┘  │
│  │ • flannel (CNI)       │                              │
│  │ • CoreDNS             │    k2s CLI (native binary)   │
│  │ • buildah             │    No PowerShell required    │
│  └───────────────────────┘                              │
│                                                         │
│  ─── KVM / libvirt (QEMU + OVMF UEFI) ──────────────── │
└─────────────────────────────────────────────────────────┘
```

On Linux, the CLI is a native Go binary that interacts directly with Kubernetes and VM management APIs — **no PowerShell dependency**. Windows VMs are provisioned through libvirt/KVM with OVMF UEFI firmware and VirtIO drivers.

### Linux Host (Inverted Setup)

A Linux machine runs the CLI natively, hosts the Kubernetes control plane directly, and provisions a Windows VM as an optional worker node:

```
┌─────────────────────────────────────────────────────────┐
│  Linux Host                                             │
│                                                         │
│  ┌───────────────────────┐    ┌──────────────────────┐  │
│  │ Linux Control Plane   │    │ Windows VM (Worker)  │  │
│  │                       │    │                      │  │
│  │ • CRI-O / containerd  │    │ • containerd         │  │
│  │ • kubelet             │    │ • kubelet            │  │
│  │ • kube-apiserver      │    │ • kube-proxy         │  │
│  │ • kube-scheduler      │    │ • flannel (CNI)      │  │
│  │ • kube-controller-mgr │    │                      │  │
│  │ • etcd                │    └──────────────────────┘  │
│  │ • flannel (CNI)       │                              │
│  │ • CoreDNS             │    k2s CLI (native binary)   │
│  │ • buildah             │    No PowerShell required    │
│  └───────────────────────┘                              │
│                                                         │
│  ─── KVM / libvirt (QEMU + OVMF UEFI) ──────────────── │
└─────────────────────────────────────────────────────────┘
```

On Linux, the CLI is a native Go binary that interacts directly with Kubernetes and VM management APIs — **no PowerShell dependency**. Windows VMs are provisioned through libvirt/KVM with OVMF UEFI firmware and VirtIO drivers.

### Key Design Decisions

- **Flannel CNI with host-gateway mode** — routes pod traffic directly through host routing tables for maximum performance and simplicity. A VXLAN backend template is also available.
- **Mixed OS support** — Windows containers run on one node via containerd; Linux containers run on the other via CRI-O.
- **Offline-first** — all dependencies are bundled or downloadable as offline packages. No runtime network fetches unless explicitly triggered.
- **Single-binary CLI** — `k2s` is the only user-facing tool; all operations route through it.
- **Dual-platform host support** — the same CLI binary (built for each platform via Go build tags) runs on both Windows and Linux hosts. Platform differences are encapsulated in the [Provider Architecture](#provider-architecture).
- **Provider abstraction** — command handlers are platform-agnostic; all platform-specific logic lives behind provider interfaces (see below).
- **Single-binary CLI** — `k2s` is the only user-facing tool; all operations route through it.
- **Dual-platform host support** — the same CLI binary (built for each platform via Go build tags) runs on both Windows and Linux hosts. Platform differences are encapsulated in the [Provider Architecture](#provider-architecture).
- **Provider abstraction** — command handlers are platform-agnostic; all platform-specific logic lives behind provider interfaces (see below).

### Hosting Variants

| Variant | `kind` | Host OS | Worker VM | Use Case |
|---------|--------|---------|-----------|----------|
| Host (default) | `k2s` | Windows | Linux VM (control plane + worker) | Full mixed-OS cluster |
| Host + Linux-Only | `k2s` + `--linux-only` | Windows | Linux VM (control plane only) | Linux-only workloads |
| Host + WSL 2 | `k2s` + `--wsl` | Windows | Linux VM via WSL 2 | Lighter footprint, shared kernel |
| Development-Only | `buildonly` | Windows | Linux VM | Container image building only, no K8s |
| Linux Host | `k2s` | Linux | Windows VM (worker, optional) | **Experimental** — Inverted setup, Linux-native control plane |

See [Hosting Variants](../user-guide/hosting-variants.md) and the [Features Matrix](hosting-variants-features-matrix.md) for detailed comparisons.

---

## Provider Architecture

The Go CLI uses a **provider pattern** to abstract all platform-specific operations behind a set of domain interfaces. This decouples command handlers from platform details and makes it straightforward to add new host platforms.

### Design

```
┌──────────────────────────────────────────────────────────┐
│  Command Layer (cmd/k2s/cmd/)                            │
│  install.go, start.go, stop.go, uninstall.go, ...       │
│                                                          │
│  context.Providers().Cluster.Install(config)             │
│  context.Providers().Image.Build(config)                 │
│  context.Providers().System.Package(config)              │
└──────────────┬───────────────────────────────────────────┘
               │ (interface calls)
┌──────────────▼───────────────────────────────────────────┐
│  Provider Interfaces (internal/provider/)                 │
│                                                          │
│  ClusterProvider   — Install, Uninstall, Start, Stop     │
│  ImageProvider     — Build, Import, Export, List, Remove │
│  NodeProvider      — Add, Remove, List                   │
│  SystemProvider    — Package, Upgrade, Backup, Restore   │
│  AddonProvider     — Enable, Disable, Status             │
└──────────────┬──────────────────┬────────────────────────┘
        ┌──────┘                  └──────┐
┌───────▼──────────────┐  ┌──────────────▼─────────────────┐
│  Windows Provider     │  │  Linux Provider                │
│  (*_windows.go)       │  │  (*_linux.go)                  │
│                       │  │                                │
│  Delegates to PS      │  │  Native Go: kubeadm, kubectl,  │
│  via ExecutePs...     │  │  libvirt/KVM, SSH, crictl      │
│  Supports all setup   │  │  No PowerShell dependency      │
│  types (k2s, linux-   │  │                                │
│  only, buildonly)     │  │                                │
└───────────────────────┘  └────────────────────────────────┘
```

### Key Components

| File | Purpose |
|------|---------|
| `provider.go` | `Registry` struct (holds all providers) and `ProviderConfig` |
| `cluster.go` | `ClusterProvider` interface — Install, Uninstall, Start, Stop, Status |
| `image.go` | `ImageProvider` interface — Build, Import, Export, List, Remove |
| `node.go` | `NodeProvider` interface — Add, Remove, List |
| `system.go` | `SystemProvider` interface — Package, Upgrade, Backup, Restore |
| `addon.go` | `AddonProvider` interface — Enable, Disable, Status |
| `errors.go` | `ErrNotSupported` sentinel, `UnsupportedOperationError` |
| `registry_windows.go` | Build-tagged factory creating Windows providers |
| `registry_linux.go` | Build-tagged factory creating Linux providers |

### How It Works

1. During CLI initialisation (`PersistentPreRunE` in `cmd.go`), a `provider.Registry` is created via `provider.NewRegistry(config)`. The build-tagged factory selects Windows or Linux implementations.
2. The registry is stored in the Cobra command context via `CmdContext`.
3. Command handlers call `context.Providers().Cluster.Start(...)` etc. — no `if runtime.GOOS == ...` checks anywhere in command code.
4. On **Windows**, providers delegate to PowerShell scripts via `ExecutePsWithStructuredResult`, exactly preserving the existing Go ↔ PS bridge.
5. On **Linux**, providers use native Go APIs (kubeadm, kubectl, libvirt, SSH) with no PowerShell dependency.
6. Operations not available on the current platform return `provider.ErrNotSupported`.

### Adding a New Provider Domain

1. Define the interface in `internal/provider/<domain>.go`.
2. Create `<domain>_windows.go` and `<domain>_linux.go` with concrete implementations.
3. Add the provider field to `Registry` and wire it in both `registry_*.go` factories.
4. Call the provider from the relevant command handler via `context.Providers().<Domain>.Method()`.

---

## Bundled Tools

*K2s* ships several supporting executables beyond the main `k2s.exe` CLI. All are built from Go source under `k2s/cmd/` and placed in the `bin/` directory.

### Networking Tools

| Tool | Source | Purpose |
|------|--------|---------|
| **httpproxy.exe** | `k2s/cmd/httpproxy/` | HTTP forward proxy running on the Windows host. Transparently proxies internet traffic for the Linux VM when a corporate proxy is configured. |
| **vfprules.exe** | `k2s/cmd/vfprules/` | Manages Virtual Filtering Platform (VFP) rules on the `cbr0` Hyper-V external switch. Routes pod and service traffic between the host and the Linux VM. |
| **bridge.exe** | `k2s/cmd/bridge/` | Windows CNI bridge plugin (based on Microsoft's windows-container-networking). Creates the `cbr0` bridge for pod networking on the Windows worker. |
| **l4proxy.exe** | `k2s/cmd/l4proxy/` | Layer 4 (TCP/UDP) proxy used in CNI networking for forwarding traffic between network namespaces. |

### VM & Provisioning Tools

| Tool | Source | Purpose |
|------|--------|---------|
| **cloudinitisobuilder.exe** | `k2s/cmd/cloudinitisobuilder/` | Builds cloud-init ISO images (ISO 9660) for provisioning the Linux VM with network config, SSH keys, and initial setup scripts. |
| **devgon.exe** | `k2s/cmd/devgon/` | Go reimplementation of Microsoft's `devcon.exe` (Device Console). Manages network adapters without requiring the VC Runtime (`vcruntime140.dll`). |

### Service Mesh & Security Tools

| Tool | Source | Purpose |
|------|--------|---------|
| **cplauncher.exe** | `k2s/cmd/cplauncher/` | Compartment Launcher — starts Windows processes inside a specific network compartment, enabling Linkerd service mesh on Windows. Resolves compartments from Kubernetes pod labels and optionally injects a DLL for per-thread compartment switching. |
| **login.exe** | `k2s/cmd/login/` | OAuth2/OIDC login provider using Ory Hydra. Provides Windows-logon-based authentication for the security addon's zero-trust mode. |

### Container Tools

| Tool | Source | Purpose |
|------|--------|---------|
| **pause.exe** | `k2s/cmd/pause/` | Windows pause container. Every Windows pod includes this as the infrastructure container (holds the network namespace). Ships with its own Dockerfile. |

### Utilities

| Tool | Source | Purpose |
|------|--------|---------|
| **yaml2json.exe** | `k2s/cmd/yaml2json/` | Converts YAML to JSON. Used internally by scripts that need JSON input from YAML sources. |
| **zap.exe** | `k2s/cmd/zap/` | Forcefully removes directories that Windows file locks prevent from being deleted (used by `k2s image reset-win-storage --force-zap`). |

### Building Tools from Source

All Go tools can be built locally using the build script:

```console
# Build k2s.exe only
bgo

# Build a specific tool
bgo -ProjectDir "k2s\cmd\httpproxy" -ExeOutDir "bin"

# Build all Go executables
bgo -BuildAll
```

See [Building Locally](contributing/building-locally.md) for prerequisites.

---

## PowerShell Module Structure

*K2s* organises its PowerShell automation into four major modules under `lib/modules/k2s/`:

### k2s.infra.module — Infrastructure & Configuration

| Submodule | Purpose |
|-----------|---------|
| `config/config.module.psm1` | Reads and writes cluster configuration (`setup.json`, `config.json`). Exports ~50 functions for querying setup type, flags, proxy settings, mirror registries, K8s version, etc. |
| `config/cluster.config.module.psm1` | Multi-node cluster topology management (`cluster.json`). CRUD operations for node entries. |
| `hooks/hooks.module.psm1` | Hook system — discovers and executes lifecycle hook scripts. See [Hook System](../op-manual/hook-system.md). |
| `network/` | Windows host network management (adapters, routes, DNS). |
| `validation/` | Path validation, pattern matching, hashtable comparison utilities. |
| `dump/` | Diagnostic dump file generation. |
| `path/` | K2s installation path resolution. |
| `log/` | Logging infrastructure (`Write-Log`, `Write-ErrorMessage`). |

### k2s.cluster.module — Cluster Lifecycle

| Submodule | Purpose |
|-----------|---------|
| `upgrade/` | Full cluster upgrade orchestration (export/import resources, uninstall/install, re-enable addons). |
| `update/` | Delta update application (in-place file replacement, Debian package diff, container image update). |
| `system/` | Time sync, API server readiness checks, node label/taint management. |
| `image/` | Container image management and backup/restore of images. |
| `setupinfo/` | Setup information queries. |
| `runningstate/` | Cluster running state checks. |
| `k8s-api/` | Kubernetes API integration helpers. |

### k2s.node.module — Node Management

| Submodule | Purpose |
|-----------|---------|
| `linuxnode/baseimage/` | Linux VM base image building, cloud-init provisioning templates. |
| `linuxnode/distros/` | Multi-distro support: Debian and Ubuntu with distro-specific network configuration. |
| `linuxnode/security/` | SSH key generation and deployment (`New-SshKey`, `Copy-LocalPublicSshKeyToRemoteComputer`). |
| `linuxnode/vm/` | Hyper-V VM lifecycle management for the control-plane node. |
| `windowsnode/` | Windows worker node setup: base image, binary downloads, network config, proxy, services, system configuration. |
| `vmnode/` | Generic VM node management for additional cluster nodes. |

### k2s.signing.module — Code Signing

| Function | Purpose |
|----------|---------|
| `Set-K2sFileSignature` | Signs all K2s executables (.exe, .dll, .msi) and PowerShell scripts (.ps1, .psm1) using a PFX certificate with Authenticode. |
| `Get-SignableFiles` | Discovers signable files with built-in exclusion lists. |

See [Security Features](../security/security-features.md) for details.

---

## Script Layers

| Layer | Location | Purpose |
|-------|----------|---------|
| **CLI orchestration** | `lib/scripts/k2s/` | Top-level scripts invoked by `k2s.exe`: install, start, stop, upgrade, backup, restore, image management, proxy, certificates, packaging. |
| **Host provisioning** | `smallsetup/` | Windows host environment bootstrap: loopback adapter, HNS network, kubeadm flags, debug helpers, network repair scripts. |
| **Addon lifecycle** | `addons/` | Per-addon Enable/Disable/Backup/Restore/Update/Get-Status scripts and Kubernetes manifests. |
| **Multi-variant installs** | `lib/scripts/buildonly/`, `lib/scripts/linuxonly/` | Variant-specific install/uninstall/start/stop scripts. |
| **Worker node setup** | `lib/scripts/worker/` | Setup scripts for Windows and Linux worker nodes. |
| **Control plane setup** | `lib/scripts/control-plane/` | Control plane installation script. |
| **Packaging** | `lib/scripts/k2s/system/package/` | Full and delta package creation, image acquisition, signing, Debian diff, addon packaging. |

---

## Configuration Files Overview

| File | Location | Purpose |
|------|----------|---------|
| `config.json` | `cfg/` | Network CIDRs, registries, VFP rules, backup exclusions |
| `config.toml.template` | `cfg/containerd/` | Containerd runtime configuration template |
| `net-conf.json.template` | `cfg/cni/` | Flannel host-gw CNI backend |
| `net-conf-vxlan.json.template` | `cfg/cni/` | Flannel VXLAN CNI backend |
| `applockerrules.xml` | `cfg/applocker/` | AppLocker policies for container accounts |
| `joinnode.template.yaml` | `cfg/kubeadm/` | Windows node kubeadm join template |
| `joinnode-linux.template.yaml` | `cfg/kubeadm/` | Linux node kubeadm join template |

See [Configuration Reference](../op-manual/configuration-reference.md) for detailed documentation of each file.

## See Also

- [Configuration Reference](../op-manual/configuration-reference.md) — all config files and settings
- [Hosting Variants](../user-guide/hosting-variants.md) — setup types
- [Networking Architecture](../op-manual/networking-architecture.md) — CNI and network design
- [Building Locally](contributing/building-locally.md) — building Go tools from source
