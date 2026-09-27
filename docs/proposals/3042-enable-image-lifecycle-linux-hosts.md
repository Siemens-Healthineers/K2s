<!--
SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
SPDX-License-Identifier: MIT
-->

# Implementation Proposal: Enable Image Lifecycle Commands on Linux Hosts

**Issue Reference**: [#3042](https://github.com/Siemens-Healthineers/K2s/issues/3042) — *[Reverted Setup Linux] Enable image lifecycle commands on Linux hosts*  
**Related Discussion**: [#3028](https://github.com/Siemens-Healthineers/K2s/discussions/3028) — *Host Automation Script Layout Options*  
**Related Commits / Prior Work**:
- `e7342e6b3` — *#1149 reverted setup: refactor to use os providers (#1960)* by Dieter Krotz
- `4151d2f09` — *#1149 reverted setup: improved with providers (#1970)* by Dieter Krotz
- `92bd3a349` — *#1149 reverted setup: addon providers introduced (#1986)* by Dieter Krotz
- Branch `3044-reverted-setup-windows-worker` (`fc1147b32`, `304b91852`, `5406bdbd3`, `894b361f9`, `5604dab22`) by Dieter Krotz

---

## 1. Executive Summary

In K2s, the **reverted setup** (also referred to as the *Linux host* or *inverted setup*) runs the Kubernetes control plane directly on a native Linux (Debian 13) host. In commit `e7342e6b3` and subsequent enhancements (`4151d2f09`), Dieter Krotz introduced the **Provider Architecture** (`internal/provider/`) to decouple the platform-agnostic CLI command layer (`cmd/k2s/cmd/`) from host-specific automation, removing all `runtime.GOOS` switches from the CLI commands.

Subsequently, GitHub Discussion [#3028](https://github.com/Siemens-Healthineers/K2s/discussions/3028) finalized the repository-wide script layout standard under **Option 3: Incremental Migration to a Symmetric Platform-First Structure**. Under this agreement:
1. **Host automation** is organized symmetrically:
   - Windows host scripts: PowerShell scripts under `lib/scripts/windows/host/` backed by PowerShell modules under `lib/modules/windows/`.
   - Linux host scripts: Bash scripts under `lib/scripts/linux/debian/host/` backed by reusable Bash modules under `lib/modules/linux/`.
2. **Business logic is shared and duplication minimized** via the **Reusable Bash Module Model**:
   - Common utilities (`logging.sh`, `command.sh`, `validation.sh`, `paths.sh`) and container/node operations (`crio.sh`, `buildah.sh`, `packages.sh`) live in `lib/modules/linux/`.
   - Both host automation scripts (`lib/scripts/linux/debian/host/`) and node-extension scripts (`cfg/nodeextension/<os>/scripts/`) source these shared modules directly.
   - Script entry points stay thin and delegate execution to reusable module functions.
3. Linux host commands must **never** execute PowerShell; they interact with native Linux container tools (`crictl`, `ctr`, `nerdctl`, `buildah`, `systemd`) directly or through symmetric Bash host scripts.

Currently, the CLI prematurely rejects image operations after `k2s install --linux-only` via unconditional checks (`if runtimeConfig.InstallConfig().LinuxOnly() { return common.CreateFuncUnavailableForLinuxOnlyCmdFailure() }`), even though `internal/provider/image_linux.go` already implements initial operations. Furthermore, `k2s image registry add` and `remove` bypass the provider layer entirely and directly invoke Windows PowerShell scripts.

This proposal specifies the complete implementation to:
- Adopt the Discussion #3028 symmetric script layout for Linux image automation (`lib/scripts/linux/debian/host/image/`).
- Create reusable Bash modules (`lib/modules/linux/node/crio.sh`, `lib/modules/linux/node/buildah.sh`) to eliminate code duplication between host automation and node extensions.
- Eliminate duplicated inline bash generation from Windows PowerShell scripts by sharing module contracts.
- Route all image commands, including registry management, through `context.Providers().Image`.
- Enable all image lifecycle commands on Linux hosts (`build`, `clean`, `rm`, `export`, `push`, `tag`, `registry add`, `registry rm`).
- Provide actionable validation errors for unsupported Windows-only flags (`--windows`) and multi-node selectors (`--nodes`).
- Provide unit tests and an end-to-end integration test validating the entire image lifecycle on a Linux-only cluster.

---

## 2. Problem Statement & Scope

### 2.1 Affected Commands

The following commands are currently blocked after `k2s install --linux-only`:

| Command | File | Current Failure Mechanism | Target Behavior on Linux Host |
|---|---|---|---|
| `k2s image build` | `cmd/k2s/cmd/image/build.go` | Unconditional `LinuxOnly()` check | Build Linux image via `Build-Image.sh` (`nerdctl build`); reject `--windows` with actionable error. |
| `k2s image clean` | `cmd/k2s/cmd/image/clean.go` | Unconditional `LinuxOnly()` check | Remove non-K8s images via `Clean-Images.sh` (`crictl rmi`); validate node selector. |
| `k2s image rm` | `cmd/k2s/cmd/image/remove.go` | Unconditional `LinuxOnly()` check | Remove image via `Remove-Image.sh` (`crictl rmi`); validate node selector. |
| `k2s image export` | `cmd/k2s/cmd/image/export.go` | Unconditional `LinuxOnly()` check | Export image via `Export-Image.sh` (`ctr images export` or `nerdctl save`); validate node selector. |
| `k2s image push` | `cmd/k2s/cmd/image/push.go` | Unconditional `LinuxOnly()` check | Push image via `Push-Image.sh` (`nerdctl push`); resolve ImageId if needed; validate node selector. |
| `k2s image tag` | `cmd/k2s/cmd/image/tag.go` | Unconditional `LinuxOnly()` check | Tag image via `Tag-Image.sh` (`ctr images tag`); resolve ImageId if needed; validate node selector. |
| `k2s image registry add` | `cmd/k2s/cmd/image/registry/add.go` | Unconditional `LinuxOnly()` check + direct PowerShell call | Route through `ImageProvider`; execute `Add-Registry.sh` to configure `/etc/containers/registries.conf.d/` and auth without PowerShell. |
| `k2s image registry rm` | `cmd/k2s/cmd/image/registry/remove.go` | Unconditional `LinuxOnly()` check + direct PowerShell call | Route through `ImageProvider`; execute `Remove-Registry.sh` to clean config and auth without PowerShell. |

*(Note: `k2s image ls`, `k2s image pull`, and `k2s image import` are already routed through `context.Providers().Image` in Go, but their underlying Linux scripts/helpers will be aligned with the Discussion #3028 layout).*

### 2.2 Alignment with Dieter Krotz's Provider Pattern

In commit `e7342e6b3`, Dieter Krotz established the core provider architectural pattern:
> *"Command handlers in `cmd/k2s/cmd/` call provider interfaces exclusively, eliminating any `runtime.GOOS` checks or build-tagged dispatch files from the command layer. All platform differences are encapsulated here."*

Directly invoking PowerShell in `cmd/k2s/cmd/image/registry/add.go` and `remove.go` violates this separation. Moving registry management into `ImageProvider`:
- `cmd/k2s/cmd/image/registry/` calls `context.Providers().Image.RegistryAdd(...)` and `RegistryRemove(...)`.
- `windowsImageProvider` (`image_windows.go`) executes the PowerShell scripts (`lib/scripts/windows/host/image/registry/Add-Registry.ps1`, `Remove-Registry.ps1`).
- `linuxImageProvider` (`image_linux.go`) executes the symmetric Linux Bash scripts (`lib/scripts/linux/debian/host/image/registry/Add-Registry.sh`, `Remove-Registry.sh`).

---

## 3. Architecture Foundation: Discussion #3028 & Reusable Bash Module Model

### 3.1 Symmetric Platform-First Structure (Option 3)

Discussion [#3028](https://github.com/Siemens-Healthineers/K2s/discussions/3028) established a **symmetric automation architecture** between Windows and Linux. The repository distinguishes between **Host Automation** (which configures the host operating system) and **Node-Extension Automation** (which provisions remote nodes):

```
lib/
  scripts/
    windows/
      host/
        image/
          Build-Image.ps1
          Clean-Images.ps1
          Export-Image.ps1
          Get-Images.ps1
          Import-Image.ps1
          Pull-Image.ps1
          Push-Image.ps1
          Remove-Image.ps1
          Tag-Image.ps1
          registry/
            Add-Registry.ps1
            Remove-Registry.ps1
            List-Registries.ps1
          Image-Common.module.psm1

    linux/
      debian/
        host/
          image/
            Build-Image.sh
            Clean-Images.sh
            Export-Image.sh
            Get-Images.sh
            Import-Image.sh
            Pull-Image.sh
            Push-Image.sh
            Remove-Image.sh
            Tag-Image.sh
            registry/
              Add-Registry.sh
              Remove-Registry.sh
              List-Registries.sh

  modules/
    windows/
      infra/
      cluster/
      node/
      common/

    linux/
      common/
        logging.sh
        command.sh
        validation.sh
        paths.sh
      infra/
        proxy.sh
        filesystem.sh
      cluster/
        lifecycle.sh
        kubeadm.sh
      node/
        packages.sh
        crio.sh          <-- [NEW] Shared CRI-O configuration & service management
        buildah.sh       <-- [NEW] Shared Buildah auth & login management
      services/
        systemd.sh

cfg/
  nodeextension/
    debian13/
      scripts/
        download-k8s-packages.sh
        install-k8s-packages.sh
        download-buildah-packages.sh
        install-buildah-packages.sh
```

### 3.2 Minimizing Script Duplication & Sharing Business Logic

A key user requirement is **minimal code duplication between PowerShell and shell scripts, sharing business logic as much as possible**. This proposal accomplishes this across three dimensions:

#### 1. Intra-Linux Sharing via the Reusable Bash Module Model
- Instead of writing monolithic, standalone Bash scripts that re-implement argument parsing, logging, TOML formatting, or CRI-O restarts, all low-level business logic is consolidated in `lib/modules/linux/node/crio.sh` and `lib/modules/linux/node/buildah.sh`.
- Entry-point scripts in `lib/scripts/linux/debian/host/image/` are **thin dispatchers** (15–30 lines) that source modules and call functions.
- **Node-Extension Reuse**: Future and existing Linux node extensions (`cfg/nodeextension/debian13/scripts/` or `cfg/nodeextension/ubuntu/scripts/`) source the **exact same** modules (`source "${K2S_INSTALL_DIR}/lib/modules/linux/node/crio.sh"`). There is zero duplicated logic between host automation and node extension.

#### 2. Cross-Platform Deduplication: Eliminating Inline Bash from PowerShell
- In the current Windows implementation (`lib/scripts/windows/host/image/registry/Add-Registry.ps1`, lines 84–115), PowerShell contains duplicated, inline Bash strings:
  ```powershell
  $registryConfigCmd = "echo '$registryConfigBase64' | base64 -d | sudo tee /etc/containers/registries.conf.d/$fileName.conf > /dev/null"
  $loginSuccess = (Invoke-CmdOnControlPlaneViaSSHKey "sudo ${proxyCmd}buildah login ...")
  ```
- By introducing standard Linux modules (`crio.sh`, `buildah.sh`) and scripts (`Add-Registry.sh`), PowerShell targeting a remote Linux control-plane or Linux worker node invokes the native Linux script or module function via SSH, rather than synthesizing fragile shell strings. This eliminates cross-platform duplicate logic.

#### 3. Shared Go Abstraction Layer
- Parameter parsing, flag mutual exclusion, cluster status checks, node-topology validation, and JSON result serialization remain in the compiled Go layer (`cmd/k2s/cmd/image/`), shared 100% across all platforms.

---

## 4. Detailed Technical Specification

### 4.1 Reusable Bash Modules (`lib/modules/linux/`)

#### 4.1.1 `lib/modules/linux/node/crio.sh`
Consolidates CRI-O registry configuration, TOML file generation, and runtime reloading.

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_CRIO_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_CRIO_SH_LOADED=1

source "${K2S_INSTALL_DIR}/lib/modules/linux/common/logging.sh"
source "${K2S_INSTALL_DIR}/lib/modules/linux/common/validation.sh"

readonly K2S_CONTAINERS_REGISTRIES_DIR="/etc/containers/registries.conf.d"

# Formats and writes the TOML registry configuration drop-in file
k2s_crio_add_registry() {
  local registry="$1"
  local insecure="${2:-false}"

  [[ -n "$registry" ]] || { k2s_log ERROR "Registry name cannot be empty"; return 1; }

  local file_name
  file_name="${registry//:/}"
  local config_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${file_name}.conf"

  k2s_log INFO "Configuring registry drop-in at $config_file (insecure=$insecure)"
  mkdir -p "$K2S_CONTAINERS_REGISTRIES_DIR" || return 1

  cat <<EOF > "$config_file"
[[registry]]
location = "${registry}"
insecure = ${insecure}
EOF
  chmod 644 "$config_file"
}

# Removes the TOML registry configuration drop-in file
k2s_crio_remove_registry() {
  local registry="$1"
  [[ -n "$registry" ]] || { k2s_log ERROR "Registry name cannot be empty"; return 1; }

  local file_name
  file_name="${registry//:/}"
  local config_file="${K2S_CONTAINERS_REGISTRIES_DIR}/${file_name}.conf"

  if [[ -f "$config_file" ]]; then
    k2s_log INFO "Removing registry drop-in $config_file"
    rm -f "$config_file"
  else
    k2s_log WARN "Registry configuration file $config_file not found; skipping removal"
  fi
}

# Reloads systemd and restarts the CRI-O daemon
k2s_crio_reload() {
  k2s_log INFO "Reloading systemd and restarting crio service"
  systemctl daemon-reload || return 1
  systemctl restart crio || return 1
}
```

#### 4.1.2 `lib/modules/linux/node/buildah.sh`
Consolidates Buildah credentials management with transparent proxy support.

```bash
#!/usr/bin/env bash
# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
# SPDX-License-Identifier: MIT

if [[ -n ${K2S_BUILDAH_SH_LOADED:-} ]]; then
  return 0
fi
readonly K2S_BUILDAH_SH_LOADED=1

source "${K2S_INSTALL_DIR}/lib/modules/linux/common/logging.sh"
source "${K2S_INSTALL_DIR}/lib/modules/linux/infra/proxy.sh"

readonly K2S_CONTAINER_AUTH_FILE="/root/.config/containers/auth.json"

k2s_buildah_login() {
  local registry="$1"
  local user="$2"
  local password="$3"
  local skip_tls_verify="${4:-false}"

  mkdir -p "$(dirname "$K2S_CONTAINER_AUTH_FILE")"

  local tls_flag=""
  if [[ "$skip_tls_verify" == "true" ]]; then
    tls_flag="--tls-verify=false"
  fi

  k2s_log INFO "Logging into registry '$registry' via buildah"
  if [[ -n "$user" && -n "$password" ]]; then
    buildah login --authfile "$K2S_CONTAINER_AUTH_FILE" $tls_flag -u "$user" -p "$password" "$registry" >/dev/null 2>&1 || {
      k2s_log ERROR "Buildah login to '$registry' failed"
      return 1
    }
  fi
}

k2s_buildah_logout() {
  local registry="$1"
  k2s_log INFO "Logging out of registry '$registry' via buildah"
  buildah logout --authfile "$K2S_CONTAINER_AUTH_FILE" "$registry" >/dev/null 2>&1 || true
}
```

---

### 4.2 Linux Host Image Scripts (`lib/scripts/linux/debian/host/image/`)

Each script serves as a clean entry point that can be executed either directly by `linuxImageProvider` or during troubleshooting:

1. **`Build-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-d <folder>`, `-f <dockerfile>`, `-n <name>`, `-t <tag>`, `--push`, `--build-arg <k=v>`.
   - Executes: `nerdctl build` (with tags and build-args), followed by `nerdctl push` if requested.
2. **`Clean-Images.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Lists images via `crictl images -o json`, filters out Kubernetes control plane images (`registry.k8s.io`, `calico`, `flannel`), and removes user images via `crictl rmi`.
3. **`Remove-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-i <image-id>`, `-n <image-name>`, `--force`.
   - Executes: `crictl rmi [--force] <ref>`.
4. **`Export-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-i <image-id>`, `-n <image-name>`, `-t <tar-path>`, `--docker-archive`.
   - Executes: `nerdctl -n k8s.io save -o <tar>` if `--docker-archive`, else `ctr -n k8s.io images export <tar> <ref>`.
5. **`Import-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-t <tar-path>`, `-d <dir-path>`.
   - Executes: `ctr -n k8s.io images import <file>` for tar file or directory of tar files.
6. **`Pull-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-n <image-name>`.
   - Executes: `crictl pull <image-name>`.
7. **`Push-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-n <image-name>`.
   - Executes: `nerdctl push <image-name>`.
8. **`Tag-Image.sh`**:
   - Sources: `logging.sh`, `command.sh`.
   - Arguments: `-i <image-id>`, `-n <image-name>`, `-t <target-name>`.
   - Executes: `ctr -n k8s.io images tag <source> <target>`.
9. **`registry/Add-Registry.sh`**:
   - Sources: `logging.sh`, `crio.sh`, `buildah.sh`.
   - Arguments: `--registry <name>`, `--username <user>`, `--password <pass>`, `--skip-verify`, `--plain-http`.
   - Calls `k2s_crio_add_registry`, `k2s_buildah_login`, and `k2s_crio_reload`.
10. **`registry/Remove-Registry.sh`**:
    - Sources: `logging.sh`, `crio.sh`, `buildah.sh`.
    - Arguments: `--registry <name>`.
    - Calls `k2s_crio_remove_registry`, `k2s_buildah_logout`, and `k2s_crio_reload`.

---

### 4.3 Provider Layer Updates

#### 4.3.1 Extending `ImageProvider` Interface (`internal/provider/image.go`)

Add registry configuration methods and configuration structs:

```go
// ImageProvider abstracts container image operations across operating systems.
type ImageProvider interface {
    List(config ImageListConfig) (*ImageListResult, error)
    Pull(config ImagePullConfig) error
    Remove(config ImageRemoveConfig) error
    Build(config ImageBuildConfig) error
    Import(config ImageImportConfig) error
    Export(config ImageExportConfig) error
    Tag(config ImageTagConfig) error
    Push(config ImagePushConfig) error
    Clean(config ImageCleanConfig) error

    // RegistryAdd configures access to a container registry.
    RegistryAdd(config ImageRegistryAddConfig) error

    // RegistryRemove removes access to a container registry.
    RegistryRemove(config ImageRegistryRemoveConfig) error
}

type ImageRegistryAddConfig struct {
    RegistryName string
    Username     string
    Password     string
    SkipVerify   bool
    PlainHttp    bool
    Nodes        string
    ShowOutput   bool
}

type ImageRegistryRemoveConfig struct {
    RegistryName string
    Nodes        string
    ShowOutput   bool
}
```

#### 4.3.2 Updating `linuxImageProvider` (`internal/provider/image_linux.go`)

The Linux provider delegates to the symmetric Bash host scripts under `lib/scripts/linux/debian/host/image/`:

```go
type linuxImageProvider struct {
    installDir string
    configDir  string
}

func newLinuxImageProvider(cfg ProviderConfig) *linuxImageProvider {
    return &linuxImageProvider{
        installDir: cfg.InstallDir,
        configDir:  cfg.ConfigDir,
    }
}

func (p *linuxImageProvider) scriptPath(script string) string {
    return filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", script)
}

func (p *linuxImageProvider) Build(cfg ImageBuildConfig) error {
    if cfg.Windows {
        return fmt.Errorf("building Windows container images is not supported on Linux hosts (Windows container images can only be built on Windows worker nodes)")
    }
    script := p.scriptPath("Build-Image.sh")
    args := []string{"-d", cfg.InputFolder}
    if cfg.Dockerfile != "" {
        args = append(args, "-f", cfg.Dockerfile)
    }
    if cfg.ImageName != "" {
        args = append(args, "-n", cfg.ImageName)
    }
    if cfg.ImageTag != "" {
        args = append(args, "-t", cfg.ImageTag)
    }
    if cfg.Push {
        args = append(args, "--push")
    }
    for k, v := range cfg.BuildArgs {
        args = append(args, "--build-arg", k+"="+v)
    }
    return exec.Command(script, args...).Run()
}

func (p *linuxImageProvider) RegistryAdd(cfg ImageRegistryAddConfig) error {
    script := p.scriptPath(filepath.Join("registry", "Add-Registry.sh"))
    args := []string{"--registry", cfg.RegistryName}
    if cfg.Username != "" {
        args = append(args, "--username", cfg.Username)
    }
    if cfg.Password != "" {
        args = append(args, "--password", cfg.Password)
    }
    if cfg.SkipVerify {
        args = append(args, "--skip-verify")
    }
    if cfg.PlainHttp {
        args = append(args, "--plain-http")
    }

    cmd := exec.Command(script, args...)
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("failed to add registry '%s': %w", cfg.RegistryName, err)
    }

    // Persist registry in setup.json
    return p.addRegistryToConfig(cfg.RegistryName)
}

func (p *linuxImageProvider) RegistryRemove(cfg ImageRegistryRemoveConfig) error {
    script := p.scriptPath(filepath.Join("registry", "Remove-Registry.sh"))
    cmd := exec.Command(script, "--registry", cfg.RegistryName)
    if err := cmd.Run(); err != nil {
        return fmt.Errorf("failed to remove registry '%s': %w", cfg.RegistryName, err)
    }

    // Remove registry from setup.json
    return p.removeRegistryFromConfig(cfg.RegistryName)
}
```

#### 4.3.3 Updating `windowsImageProvider` (`internal/provider/image_windows.go`)

Implement `RegistryAdd` and `RegistryRemove` by invoking the existing Windows PowerShell scripts:

```go
func (p *windowsImageProvider) RegistryAdd(cfg ImageRegistryAddConfig) error {
    psCmd := p.scriptPath(filepath.Join("registry", "Add-Registry.ps1"))
    var params []string
    params = append(params, " -RegistryName "+utils.EscapeWithSingleQuotes(cfg.RegistryName))
    if cfg.Username != "" {
        params = append(params, " -Username "+utils.EscapeWithSingleQuotes(cfg.Username))
    }
    if cfg.Password != "" {
        params = append(params, " -Password "+utils.EscapeWithSingleQuotes(cfg.Password))
    }
    if cfg.SkipVerify {
        params = append(params, " -SkipVerify")
    }
    if cfg.PlainHttp {
        params = append(params, " -PlainHttp")
    }
    if cfg.Nodes != "" {
        params = append(params, " -Nodes "+utils.EscapeWithSingleQuotes(cfg.Nodes))
    }
    if cfg.ShowOutput {
        params = append(params, " -ShowLogs")
    }
    return p.execPS(psCmd, params...)
}

func (p *windowsImageProvider) RegistryRemove(cfg ImageRegistryRemoveConfig) error {
    psCmd := p.scriptPath(filepath.Join("registry", "Remove-Registry.ps1"))
    var params []string
    params = append(params, " -RegistryName "+utils.EscapeWithSingleQuotes(cfg.RegistryName))
    if cfg.Nodes != "" {
        params = append(params, " -Nodes "+utils.EscapeWithSingleQuotes(cfg.Nodes))
    }
    if cfg.ShowOutput {
        params = append(params, " -ShowLogs")
    }
    return p.execPS(psCmd, params...)
}
```

---

### 4.4 CLI Command Layer & Topology Validation

#### 4.4.1 Node Selector Validator (`cmd/k2s/cmd/image/node_selector.go`)

Create a shared validator to ensure actionable errors when unsupported node selections or Windows-specific flags are used on Linux hosts:

```go
func validateNodeSelector(nodeSelector string, runtimeConfig *contracts.K2sRuntimeConfig) error {
    if nodeSelector == "" {
        return nil
    }

    if runtimeConfig.InstallConfig().LinuxOnly() {
        if strings.Contains(nodeSelector, ",") {
            return fmt.Errorf("multi-node selection '%s' is not supported on a Linux-only installation; only the local Linux host is available", nodeSelector)
        }

        lower := strings.ToLower(nodeSelector)
        if strings.Contains(lower, "win") {
            return fmt.Errorf("node '%s' is a Windows worker node; Linux-only installations do not contain Windows worker nodes", nodeSelector)
        }

        cpHostname := strings.ToLower(runtimeConfig.ControlPlaneConfig().Hostname())
        if lower != "linux" && lower != cpHostname {
            return fmt.Errorf("node '%s' is not part of this cluster; Linux-only installation only targets the local host node ('%s')", nodeSelector, runtimeConfig.ControlPlaneConfig().Hostname())
        }
    }

    return nil
}
```

#### 4.4.2 Unblocking CLI Handlers (`cmd/k2s/cmd/image/`)

1. **`build.go`**:
   - Remove unconditional `if runtimeConfig.InstallConfig().LinuxOnly() { return common.CreateFuncUnavailableForLinuxOnlyCmdFailure() }`.
   - Add flag check: `if runtimeConfig.InstallConfig().LinuxOnly() && buildOptions.Windows { return fmt.Errorf("building Windows container images is not supported on a Linux-only installation") }`.
   - Remove unused legacy `buildPsCmd`.

2. **`clean.go`**, **`remove.go`**, **`export.go`**, **`push.go`**, **`tag.go`**:
   - Remove unconditional `LinuxOnly()` check.
   - Insert `validateNodeSelector(nodeSelector, runtimeConfig)` check.
   - Call provider method (`Clean`, `Remove`, `Export`, `Push`, `Tag`).

3. **`registry/add.go`** & **`registry/remove.go`**:
   - Remove unconditional `LinuxOnly()` check.
   - Remove direct PowerShell imports (`internal/providers/powershell`).
   - Validate node selector via `validateNodeSelector`.
   - Call `context.Providers().Image.RegistryAdd(...)` / `RegistryRemove(...)`.

4. **`registry/list.go`**:
   - Guard node listing so it does not trigger PowerShell on Linux. If targeting the local node, return `runtimeConfig.ClusterConfig().Registries()` directly.

---

## 5. Testing & Verification Strategy

### 5.1 Unit Tests

| Test Target | Scope / Test Cases |
|---|---|
| `cmd/k2s/cmd/image/build_test.go` | • `--windows` flag on Linux-only returns actionable validation error.<br>• Linux build routes successfully to `provider.Image.Build`.<br>• Option parsing for input folder, build args, push flag. |
| `cmd/k2s/cmd/image/node_selector_test.go` | • Empty node selector permitted on Linux-only.<br>• Local control plane hostname / `"linux"` allowed.<br>• Comma-separated multi-node selector rejected with actionable error.<br>• Windows worker node names rejected. |
| `cmd/k2s/cmd/image/clean_test.go` | • Routes to `provider.Image.Clean` on Linux-only.<br>• Rejects multi-node and Windows worker selections. |
| `cmd/k2s/cmd/image/remove_test.go` | • Routes to `provider.Image.Remove` on Linux-only.<br>• Rejects missing image ID and name.<br>• Rejects multi-node selections. |
| `cmd/k2s/cmd/image/export_test.go` | • Routes to `provider.Image.Export` on Linux-only.<br>• Forwards `DockerArchive` flag correctly to provider.<br>• Rejects invalid node selections. |
| `cmd/k2s/cmd/image/tag_test.go` | • Routes to `provider.Image.Tag` on Linux-only.<br>• Validates source and target image names. |
| `cmd/k2s/cmd/image/push_test.go` | • Routes to `provider.Image.Push` on Linux-only.<br>• Validates node selections. |
| `cmd/k2s/cmd/image/registry/add_test.go` | • Routes `RegistryAdd` to provider.<br>• Validates node selector on Linux-only. |
| `cmd/k2s/cmd/image/registry/remove_test.go` | • Routes `RegistryRemove` to provider.<br>• Validates node selector on Linux-only. |
| `internal/provider/image_linux_test.go` | • Validates invocation of `Build-Image.sh`, `Add-Registry.sh`, `Remove-Registry.sh`.<br>• Rejects Windows flag in `Build`.<br>• Tests `setup.json` registry state synchronization. |

### 5.2 Updates to Existing E2E Acceptance Tests

In `test/e2e/cli/cmd/image/setuprequired/image_setuprequired_test.go`:
- Lines 48–58 currently assert that `image rm` fails with `VerifyFunctionalityNotAvailableFailure()` on Linux-only setups.
- **Update**: Remove this outdated assertion since `image rm` is now supported on Linux-only installations. Replace with validation that `image rm` without arguments returns standard syntax/argument error, or verify successful execution.

### 5.3 New Linux-Only E2E Acceptance Test

**Target File**: `test/e2e/cluster/nodeimage/image_linux_only_test.go`  
**Ginkgo Labels**: `Label("core", "acceptance", "setup-required", "system-running", "linux-only", "image")`

**Lifecycle Workflow Steps**:
1. **Pre-check**: Verify cluster is running and setup type is `LinuxOnly()`.
2. **Build**:
   - Create a minimal Docker context with a test `Dockerfile`.
   - Execute `k2s image build -d <dir> -n k2s-test-linux -t v1`.
   - Assert exit code is 0.
3. **List**:
   - Execute `k2s image ls -o json`.
   - Parse JSON output and assert `k2s-test-linux:v1` is present.
4. **Tag**:
   - Execute `k2s image tag -n k2s-test-linux:v1 -t k2s-test-linux:v2`.
   - Assert `k2s-test-linux:v2` is present in `k2s image ls`.
5. **Export**:
   - Execute `k2s image export -n k2s-test-linux:v2 -t /tmp/k2s-test-linux-v2.tar`.
   - Assert tar file exists and is non-empty.
6. **Remove**:
   - Execute `k2s image rm -n k2s-test-linux:v2`.
   - Assert `k2s-test-linux:v2` is removed.
7. **Import**:
   - Execute `k2s image import -t /tmp/k2s-test-linux-v2.tar`.
   - Assert `k2s-test-linux:v2` is restored.
8. **Registry Add/Remove**:
   - Execute `k2s image registry add test.registry.local --plain-http`.
   - Assert registry appears in `k2s image registry ls`.
   - Execute `k2s image registry rm test.registry.local`.
   - Assert registry is removed.
9. **Negative Flag Validation**:
   - `k2s image build --windows` -> Assert failure with clear message that Windows build is unsupported on Linux host.
   - `k2s image clean --nodes worker-1,worker-2` -> Assert failure with multi-node error.
10. **Cleanup**: Remove temporary tarball and test container images.

---

## 6. File Inventory & Implementation Checklist

| File | Nature of Change | Description |
|---|---|---|
| `lib/modules/linux/node/crio.sh` | **Create** | Reusable Bash module for CRI-O drop-in registry creation, deletion, and service reload. |
| `lib/modules/linux/node/buildah.sh` | **Create** | Reusable Bash module for Buildah login, logout, and auth file management. |
| `lib/scripts/linux/debian/host/image/Build-Image.sh` | **Create** | Linux host script to build container images via `nerdctl build`. |
| `lib/scripts/linux/debian/host/image/Clean-Images.sh` | **Create** | Linux host script to clean non-K8s images via `crictl rmi`. |
| `lib/scripts/linux/debian/host/image/Remove-Image.sh` | **Create** | Linux host script to remove specific images via `crictl rmi`. |
| `lib/scripts/linux/debian/host/image/Export-Image.sh` | **Create** | Linux host script to export images (OCI or Docker format). |
| `lib/scripts/linux/debian/host/image/Import-Image.sh` | **Create** | Linux host script to import images via `ctr images import`. |
| `lib/scripts/linux/debian/host/image/Pull-Image.sh` | **Create** | Linux host script to pull images via `crictl pull`. |
| `lib/scripts/linux/debian/host/image/Push-Image.sh` | **Create** | Linux host script to push images via `nerdctl push`. |
| `lib/scripts/linux/debian/host/image/Tag-Image.sh` | **Create** | Linux host script to tag images via `ctr images tag`. |
| `lib/scripts/linux/debian/host/image/registry/Add-Registry.sh` | **Create** | Linux host script sourcing `crio.sh` and `buildah.sh` to add registry access. |
| `lib/scripts/linux/debian/host/image/registry/Remove-Registry.sh` | **Create** | Linux host script sourcing `crio.sh` and `buildah.sh` to remove registry access. |
| `internal/provider/image.go` | **Modify** | Add `RegistryAdd` & `RegistryRemove` to `ImageProvider` interface; declare config structs. |
| `internal/provider/image_linux.go` | **Modify** | Implement `RegistryAdd`, `RegistryRemove`; delegate operations to Linux host scripts. |
| `internal/provider/image_windows.go` | **Modify** | Implement `RegistryAdd`, `RegistryRemove` delegating to Windows PowerShell scripts. |
| `cmd/k2s/cmd/image/node_selector.go` | **Create** | Shared node topology validator (`validateNodeSelector`). |
| `cmd/k2s/cmd/image/build.go` | **Modify** | Remove blanket `LinuxOnly()` check; reject `--windows` on Linux-only; remove dead PS code. |
| `cmd/k2s/cmd/image/clean.go` | **Modify** | Remove `LinuxOnly()` check; add node selector validation. |
| `cmd/k2s/cmd/image/remove.go` | **Modify** | Remove `LinuxOnly()` check; add node selector validation. |
| `cmd/k2s/cmd/image/export.go` | **Modify** | Remove `LinuxOnly()` check; add node selector validation; forward Docker archive flag. |
| `cmd/k2s/cmd/image/push.go` | **Modify** | Remove `LinuxOnly()` check; add node selector validation. |
| `cmd/k2s/cmd/image/tag.go` | **Modify** | Remove `LinuxOnly()` check; add node selector validation. |
| `cmd/k2s/cmd/image/registry/add.go` | **Modify** | Route through `context.Providers().Image.RegistryAdd(...)`; remove direct PowerShell call. |
| `cmd/k2s/cmd/image/registry/remove.go` | **Modify** | Route through `context.Providers().Image.RegistryRemove(...)`; remove direct PowerShell call. |
| `cmd/k2s/cmd/image/registry/list.go` | **Modify** | Prevent invoking PowerShell on Linux when listing registries. |
| `test/e2e/cli/cmd/image/setuprequired/image_setuprequired_test.go` | **Modify** | Remove obsolete assertion expecting `image rm` failure on Linux-only. |
| `test/e2e/cluster/nodeimage/image_linux_only_test.go` | **Create** | Integration test suite verifying image lifecycle on a Linux-only cluster. |

---

## 7. Acceptance Criteria Traceability Matrix

| Acceptance Criterion (Issue #3042) | Design Element & Verification |
|---|---|
| `k2s image build` builds a Linux image on a Linux-only installation. | Handled via `cmd/k2s/cmd/image/build.go` routing to `linuxImageProvider.Build`, executing `Build-Image.sh` (`nerdctl build`). Tested in unit tests and `image_linux_only_test.go`. |
| `k2s image clean`, `remove`, `export`, `push`, and `tag` invoke the Linux image provider and complete successfully. | Unblocked in `cmd/k2s/cmd/image/` handlers; executed via corresponding Bash host scripts (`Clean-Images.sh`, `Remove-Image.sh`, `Export-Image.sh`, `Push-Image.sh`, `Tag-Image.sh`). Verified in `image_linux_only_test.go`. |
| `k2s image registry add` and `remove` manage Linux-host registry configuration without PowerShell. | Routed through `ImageProvider` to `Add-Registry.sh` and `Remove-Registry.sh` (sourcing `crio.sh` and `buildah.sh`), configuring `/etc/containers/registries.conf.d/` and CRI-O reload. Verified in integration tests. |
| Commands fail early with clear errors for unsupported Windows-worker or multi-node selections. | Implemented via `validateNodeSelector(...)` in `cmd/k2s/cmd/image/node_selector.go` and flag checking in `build.go`. Verified in unit tests. |
| Unit tests cover Linux command routing and option validation. | Implemented in `cmd/k2s/cmd/image/*_test.go` and `internal/provider/image_linux_test.go`. |
| An integration test verifies build, list, export/import, tag, and remove against a Linux-only cluster. | Implemented in `test/e2e/cluster/nodeimage/image_linux_only_test.go`. |
