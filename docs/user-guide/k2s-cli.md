<!--
SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# k2s CLI

The *k2s* CLI is the primary interface for managing a *K2s* cluster. It covers the full lifecycle — installation, startup, upgrade, image management, addon management, and system maintenance.

Every command supports `--output` / `-o` (show log in terminal) and `--verbosity` / `-v` (log level, default `info`) as global flags.

```console
k2s -h
```

!!! tip
    When *K2s* is installed, the executables including *k2s* CLI have been added to `PATH`, so that the CLI can be called by using its name only.

!!! note
    Most of the *k2s* CLI commands require administrator privileges.

---

## install

Installs a *K2s* Kubernetes cluster on the host machine.

```console
k2s install [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--master-cpus` | | Number of CPUs allocated to master VM |
| `--master-memory` | | RAM for master VM (minimum 2 GB) |
| `--master-disk` | | Disk size for master VM (minimum 10 GB) |
| `--proxy` | `-p` | HTTP proxy |
| `--no-proxy` | | No-proxy hosts/domains (comma-separated) |
| `--config` | `-c` | Path to config file |
| `--wsl` | | Use WSL 2 for hosting the KubeMaster |
| `--linux-only` | | No Windows worker node |
| `--force-online-installation` | `-f` | Force online installation |
| `--delete-files-for-offline-installation` | `-d` | Delete offline-only files after online install |
| `--k8s-bins` | | Path to locally built Kubernetes binaries |
| `--skip-start` | | Do not start the cluster after installation |
| `--append-log` | | Append to existing log file |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### install buildonly

Installs a minimal *buildonly* setup (Linux VM without Windows worker node, intended for container image building only).

```console
k2s install buildonly [flags]
```

Accepts the same VM-resource, proxy, and config flags as `install`.

---

## uninstall

Removes the *K2s* cluster from the host machine.

```console
k2s uninstall [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-purge` | | Keep installation files on disk |
| `--delete-files-for-offline-installation` | `-d` | Delete offline-only files |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## start

Starts a previously installed *K2s* cluster.

```console
k2s start [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ignore-if-running` | `-i` | Skip if already running |
| `--autouse-cached-vswitch` | | Re-use the cached vSwitch (cbr0 / KubeSwitch) |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## stop

Stops the running *K2s* cluster.

```console
k2s stop [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--cache-vswitch` | | Cache vswitches for cluster connectivity |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

---

## status

Prints status information about the *K2s* cluster.

```console
k2s status [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `wide`, `json` |

---

## version

Prints the installed *K2s* version.

```console
k2s version
```

---

## image

Manage container images on the cluster nodes.

### image ls

List images on all nodes.

```console
k2s image ls [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--include-k8s-images` | `-A` | Include Kubernetes system images |
| `--output` | `-o` | Output format: `json` |

### image build

Build a container image.

```console
k2s image build [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--input-folder` | `-d` | Build context directory (default `.`) |
| `--dockerfile` | `-f` | Dockerfile location |
| `--image-name` | `-n` | Image name |
| `--image-tag` | `-t` | Image tag |
| `--build-arg` | | Build arguments (repeatable) |
| `--windows` | `-w` | Build a Windows container image |
| `--push` | `-p` | Push to private registry after build |

### image pull

Pull an image onto a Kubernetes node.

```console
k2s image pull <image> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--windows` | `-w` | Pull onto the Windows node |

### image push

Push an image into a registry.

```console
k2s image push [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--image-name` | `-n` | Image name including tag |

### image tag

Tag an existing image with a new name.

```console
k2s image tag [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--image-name` | `-n` | Current image name including tag |
| `--target-name` | `-t` | New image name including tag |

### image export

Export an image to a tar archive.

```console
k2s image export [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--name` | `-n` | Image name including tag |
| `--tar` | `-t` | Output tar file path |
| `--docker-archive` | | Export as docker-archive (default: oci-archive) |

### image import

Import an image from a tar archive.

```console
k2s image import [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--tar` | `-t` | Path to oci-archive tar |
| `--dir` | `-d` | Directory containing multiple oci-archive tars |
| `--windows` | `-w` | Import as Windows image |
| `--docker-archive` | | Import from docker-archive tar |

### image rm

Remove a container image.

```console
k2s image rm [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--id` | | Image ID |
| `--name` | | Image name |
| `--from-registry` | | Remove from local registry |
| `--force` | | Force removal (removes containers using the image first) |

### image clean

Remove all non-system container images from every node.

```console
k2s image clean
```

### image reset-win-storage

Reset the containerd and Docker image storage on Windows nodes.

```console
k2s image reset-win-storage [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--containerd` | | Containerd directory |
| `--docker` | | Docker directory |
| `--max-retry` | | Max retries for directory deletion (default `1`) |
| `--force-zap` | `-z` | Use `zap.exe` to forcefully remove directories |
| `--force` | `-f` | No user prompts |

### image registry

Manage configured container registries.

#### image registry add

```console
k2s image registry add <registry-url> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--username` | `-u` | Registry username |
| `--password` | `-p` | Registry password |
| `--skip-verify` | | Skip HTTPS certificate verification |
| `--plain-http` | | Allow plain HTTP fallback |

#### image registry rm

```console
k2s image registry rm <registry-url>
```

#### image registry ls

```console
k2s image registry ls
```

---

## addons

Manage optional cluster addons. See the [Addons](addons.md) page for a full overview.

### addons ls

List all available addons and their status.

```console
k2s addons ls [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `json` |

### addons enable / disable

Enable or disable a specific addon. The subcommands and their flags are defined dynamically from each addon's `addon.manifest.yaml`.

```console
k2s addons enable <addon> [flags]
k2s addons disable <addon>
```

!!! example
    ```console
    k2s addons enable ingress
    k2s addons enable registry
    k2s addons disable dashboard
    ```

### addons status

Print the status of a specific addon.

```console
k2s addons status <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--output` | `-o` | Output format: `json` |

### addons export

Export an addon and its container images as an OCI artifact.

```console
k2s addons export <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--directory` | `-d` | Target directory for the exported artifact |

### addons import

Import a previously exported addon from an OCI artifact.

```console
k2s addons import <addon> [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--zip` | `-z` | Path to the OCI artifact tar file |

### addons backup

Back up addon data (persistent volumes, configuration).

```console
k2s addons backup <addon> [implementation] [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Output zip file path |

### addons restore

Restore addon data from a backup.

```console
k2s addons restore <addon> [implementation] [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Input zip file path (default: newest match in `C:\Temp\k2s\Addons`) |

---

## system

Perform system-level tasks — upgrading, packaging, backup/restore, diagnostics, certificates, proxy, users, and network reset.

### system upgrade

Upgrade the installed *K2s* cluster to the version of the package (full upgrade or in-place delta update).

```console
k2s system upgrade [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-resources` | `-s` | Skip takeover of K8s resources |
| `--skip-images` | `-i` | Skip takeover of container images |
| `--delete-files` | `-d` | Delete downloaded files after upgrade |
| `--config` | `-c` | Path to config file |
| `--proxy` | `-p` | HTTP proxy |
| `--backup-dir` | `-b` | Backup directory |
| `--force` | `-f` | Force upgrade even if versions are not consecutive |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### system package

Build a *K2s* zip package (optionally offline, delta, or code-signed).

```console
k2s system package [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--target-dir` | `-d` | **Required.** Target directory |
| `--name` | `-n` | **Required.** Package zip file name |
| `--for-offline-installation` | | Create offline package |
| `--delta-package` | | Create a delta package |
| `--package-version-from` | | Base full-package zip (required with `--delta-package`) |
| `--package-version-to` | | Target full-package zip (required with `--delta-package`) |
| `--certificate` | `-c` | Code-signing certificate (.pfx) |
| `--password` | `-w` | Certificate password |
| `--profile` | | Packaging profile: `Dev` (default) or `Lite` |
| `--addons-list` | | Comma-separated addons to include |
| `--master-cpus` | | CPUs for master VM |
| `--master-memory` | | Memory for master VM |
| `--master-disk` | | Disk for master VM |
| `--proxy` | `-p` | HTTP proxy |
| `--k8s-bins` | | Path to locally built Kubernetes binaries |

### system backup

Back up the cluster (resources, persistent volumes, user images).

```console
k2s system backup [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | Output zip file path |
| `--skip-images` | | Skip container image backup |
| `--skip-pvs` | | Skip persistent volume backup |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### system restore

Restore a *K2s* cluster from a backup.

```console
k2s system restore [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file` | `-f` | **Required.** Backup zip file |
| `--error-on-failure` | `-e` | Fail on resource-restore errors |
| `--additional-hooks-dir` | | Directory with additional hook scripts |

### system dump

Dump full system status to a folder for diagnostics.

```console
k2s system dump [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--skip-open` | `-S` | Do not open the dump folder afterwards |

### system certificate renew

Renew Kubernetes certificates.

```console
k2s system certificate renew [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Force renewal |

### system proxy

Manage HTTP proxy settings for the cluster.

```console
k2s system proxy set <proxy-uri>
k2s system proxy get
k2s system proxy show
k2s system proxy reset
```

#### system proxy override

Manage no-proxy overrides.

```console
k2s system proxy override add <hosts...>
k2s system proxy override delete <hosts...>
k2s system proxy override ls
```

### system users add

Grant a Windows user access to the *K2s* cluster.

```console
k2s system users add [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--username` | `-u` | Windows user name (mutually exclusive with `--id`) |
| `--id` | `-i` | Windows user ID (mutually exclusive with `--username`) |

### system reset network

Reset the host network configuration (requires reboot).

```console
k2s system reset network [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--force` | `-f` | Force network reset |

---

## node

!!! warning "Experimental"
    All `node` subcommands are experimental.

Manage additional cluster nodes (physical machines or VMs).

### node add

Add a node to the cluster.

```console
k2s node add [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** IP address of the machine |
| `--username` | `-u` | **Required.** SSH username |
| `--name` | `-m` | Hostname |
| `--role` | `-r` | Node role (default `worker`) |
| `--node-package` | `-p` | Path to a node package ZIP for offline installation |

Use `--node-package` together with `k2s system package --node-package --os ...` when adding a Linux worker node without internet access.

### node remove

Remove a node from the cluster.

```console
k2s node remove [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--name` | `-m` | **Required.** Hostname of the machine |

### node copy

Copy files or folders between host and node.

```console
k2s node copy [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--source` | `-s` | **Required.** Source path |
| `--target` | `-t` | **Required.** Target path |
| `--reverse` | `-r` | Copy from node to host |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |

### node exec

Execute a command on a remote node.

```console
k2s node exec [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--command` | `-c` | **Required.** Command to execute |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |
| `--raw` | `-r` | Print only remote output |

### node connect

Open an interactive SSH session to a remote node.

```console
k2s node connect [flags]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--ip-addr` | `-i` | **Required.** Node IP address |
| `--username` | `-u` | **Required.** SSH username |
| `--port` | `-p` | SSH port |
| `--timeout` | | Connection timeout |