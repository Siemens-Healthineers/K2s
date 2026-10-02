// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/host"
	kjson "github.com/siemens-healthineers/k2s/internal/json"
	"gopkg.in/yaml.v3"
)

type linuxAddonProvider struct {
	installDir string
	configDir  string
}

func newLinuxAddonProvider(cfg ProviderConfig) *linuxAddonProvider {
	return &linuxAddonProvider{
		installDir: cfg.InstallDir,
		configDir:  cfg.ConfigDir,
	}
}

// addonManifest is the minimal structure parsed from addon.manifest.yaml.
type addonManifest struct {
	Metadata struct {
		Name        string `yaml:"name"`
		Description string `yaml:"description"`
	} `yaml:"metadata"`
}

func (p *linuxAddonProvider) loadManifest(addonName string) (*addonManifest, error) {
	manifestPath := filepath.Join(p.installDir, "addons", addonName, "addon.manifest.yaml")
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return nil, fmt.Errorf("cannot read addon manifest for '%s': %w", addonName, err)
	}
	var m addonManifest
	if err := yaml.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("cannot parse addon manifest for '%s': %w", addonName, err)
	}
	return &m, nil
}

func (p *linuxAddonProvider) Enable(cfg AddonEnableConfig) error {
	slog.Info("[Addon] Enabling addon", "name", cfg.Name)

	if cfg.Name == "registry" {
		return p.enableRegistry(cfg)
	}

	manifestsDir := filepath.Join(p.installDir, "addons", cfg.Name, "manifests")
	if _, err := os.Stat(manifestsDir); err != nil {
		return fmt.Errorf("addon manifests directory not found for '%s': %w", cfg.Name, err)
	}

	// Apply all YAML manifests in the addon's manifests/ directory
	if err := exec.Command("kubectl", "apply", "-f", manifestsDir, "--recursive").Run(); err != nil {
		return fmt.Errorf("kubectl apply failed for addon '%s': %w", cfg.Name, err)
	}

	// Wait for addon pods to be ready (best-effort, 120s timeout)
	slog.Info("[Addon] Waiting for addon pods to be ready", "name", cfg.Name)
	deadline := time.Now().Add(120 * time.Second)
	for time.Now().Before(deadline) {
		output, err := exec.Command("kubectl", "get", "pods", "-A",
			"-l", fmt.Sprintf("app.kubernetes.io/name=%s", cfg.Name),
			"-o", "jsonpath={.items[*].status.conditions[?(@.type=='Ready')].status}").Output()
		if err == nil {
			statuses := strings.Fields(string(output))
			if len(statuses) > 0 {
				allReady := true
				for _, s := range statuses {
					if s != "True" {
						allReady = false
						break
					}
				}
				if allReady {
					slog.Info("[Addon] Addon pods are ready", "name", cfg.Name)
					break
				}
			}
		}
		time.Sleep(3 * time.Second)
	}

	slog.Info("[Addon] Addon enabled", "name", cfg.Name)
	return nil
}

func (p *linuxAddonProvider) enableRegistry(cfg AddonEnableConfig) error {
	if p.isAddonEnabledInConfig("registry") {
		return fmt.Errorf("addon 'registry' is already enabled, nothing to do")
	}

	// 1. Create storage directory on host
	_ = exec.Command("sudo", "mkdir", "-p", "/registry", "/registry/auth", "/registry/repository").Run()

	// 2. Create registry namespace if not exists
	_ = exec.Command("kubectl", "create", "namespace", "registry").Run()

	// 3. Inject storage node hostname into persistent-volume.yaml
	pvFile := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry", "persistent-volume.yaml")
	pvOrig, err := os.ReadFile(pvFile)
	if err != nil {
		return fmt.Errorf("reading persistent-volume.yaml: %w", err)
	}

	storageNode := getNodeName()
	pvRendered := strings.Replace(string(pvOrig), "__STORAGE_NODE__", storageNode, 1)
	if err := os.WriteFile(pvFile, []byte(pvRendered), 0644); err != nil {
		return fmt.Errorf("writing persistent-volume.yaml: %w", err)
	}
	defer func() {
		_ = os.WriteFile(pvFile, pvOrig, 0644)
	}()

	// 4. Apply registry kustomize manifests
	registryManifestsDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry")
	cmd := exec.Command("kubectl", "apply", "-k", registryManifestsDir)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl apply -k registry failed: %w", err)
	}

	// 5. Wait for registry statefulset rollout
	rolloutCmd := exec.Command("kubectl", "rollout", "status", "statefulset/registry", "-n", "registry", "--timeout=180s")
	if cfg.ShowOutput {
		rolloutCmd.Stdout = os.Stdout
		rolloutCmd.Stderr = os.Stderr
	}
	if err := rolloutCmd.Run(); err != nil {
		return fmt.Errorf("registry rollout failed: %w", err)
	}

	// 6. Ensure /etc/hosts has k2s.registry.local
	ensureHostEntry("k2s.registry.local", "127.0.0.1")

	// 7. Add registry k2s.registry.local:30500 via Add-Registry.sh
	addRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Add-Registry.sh")
	if _, err := os.Stat(addRegScript); err == nil {
		addCmd := exec.Command(addRegScript, "--registry", "k2s.registry.local:30500", "--plain-http")
		if cfg.ShowOutput {
			addCmd.Stdout = os.Stdout
			addCmd.Stderr = os.Stderr
		}
		if err := addCmd.Run(); err != nil {
			slog.Warn("[Addon] Add-Registry.sh returned error", "error", err)
		}
	}

	// 8. Update setup.json
	_ = p.addAddonToConfig("registry")
	_ = p.addRegistryToConfig("k2s.registry.local:30500")

	return nil
}

func (p *linuxAddonProvider) Disable(cfg AddonDisableConfig) error {
	slog.Info("[Addon] Disabling addon", "name", cfg.Name)

	if cfg.Name == "registry" {
		return p.disableRegistry(cfg)
	}

	manifestsDir := filepath.Join(p.installDir, "addons", cfg.Name, "manifests")
	if _, err := os.Stat(manifestsDir); err != nil {
		return fmt.Errorf("addon manifests directory not found for '%s': %w", cfg.Name, err)
	}

	if err := exec.Command("kubectl", "delete", "-f", manifestsDir, "--recursive", "--ignore-not-found").Run(); err != nil {
		return fmt.Errorf("kubectl delete failed for addon '%s': %w", cfg.Name, err)
	}

	slog.Info("[Addon] Addon disabled", "name", cfg.Name)
	return nil
}

func (p *linuxAddonProvider) disableRegistry(cfg AddonDisableConfig) error {
	if !p.isAddonEnabledInConfig("registry") && !isAddonDeployed("registry") {
		return fmt.Errorf("addon 'registry' is already disabled, nothing to do")
	}

	registryManifestsDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry")
	delCmd := exec.Command("kubectl", "delete", "-k", registryManifestsDir, "--ignore-not-found")
	if cfg.ShowOutput {
		delCmd.Stdout = os.Stdout
		delCmd.Stderr = os.Stderr
	}
	_ = delCmd.Run()

	_ = exec.Command("kubectl", "delete", "namespace", "registry", "--ignore-not-found").Run()

	// Remove registry via Remove-Registry.sh
	rmRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Remove-Registry.sh")
	if _, err := os.Stat(rmRegScript); err == nil {
		rmCmd := exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500")
		if cfg.ShowOutput {
			rmCmd.Stdout = os.Stdout
			rmCmd.Stderr = os.Stderr
		}
		_ = rmCmd.Run()
	}

	// Update setup.json
	_ = p.removeAddonFromConfig("registry")
	_ = p.removeRegistryFromConfig("k2s.registry.local:30500")

	return nil
}

func (p *linuxAddonProvider) List(_ AddonListConfig) (*AddonListResult, error) {
	slog.Debug("[Addon] Listing addons")

	addonsDir := filepath.Join(p.installDir, "addons")
	entries, err := os.ReadDir(addonsDir)
	if err != nil {
		return nil, fmt.Errorf("cannot read addons directory: %w", err)
	}

	result := &AddonListResult{}
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		manifestPath := filepath.Join(addonsDir, entry.Name(), "addon.manifest.yaml")
		if _, err := os.Stat(manifestPath); err != nil {
			continue // not an addon directory
		}

		m, err := p.loadManifest(entry.Name())
		if err != nil {
			slog.Warn("[Addon] Could not load manifest", "addon", entry.Name(), "error", err)
			continue
		}

		// Check if addon has resources in the cluster (simple heuristic)
		enabled := isAddonDeployed(entry.Name())

		result.Addons = append(result.Addons, AddonInfo{
			Name:        m.Metadata.Name,
			Enabled:     enabled,
			Description: m.Metadata.Description,
		})
	}

	return result, nil
}

func (p *linuxAddonProvider) Status(cfg AddonStatusConfig) (*AddonStatusResult, error) {
	list, err := p.List(AddonListConfig{})
	if err != nil {
		return nil, err
	}

	result := &AddonStatusResult{}
	for _, addon := range list.Addons {
		if cfg.Name != "" && addon.Name != cfg.Name {
			continue
		}
		info := AddonStatusInfo{
			Name:    addon.Name,
			Enabled: addon.Enabled,
		}

		if addon.Enabled {
			// Check pod status for this addon
			output, err := exec.Command("kubectl", "get", "pods", "-A",
				"-l", fmt.Sprintf("app.kubernetes.io/name=%s", addon.Name),
				"-o", "jsonpath={range .items[*]}{.metadata.name}={.status.phase}{','}{end}").Output()
			if err != nil || len(strings.TrimSpace(string(output))) == 0 {
				output, _ = exec.Command("kubectl", "get", "pods", "-A",
					"-l", fmt.Sprintf("app=%s", addon.Name),
					"-o", "jsonpath={range .items[*]}{.metadata.name}={.status.phase}{','}{end}").Output()
			}
			if len(strings.TrimSpace(string(output))) == 0 {
				output, _ = exec.Command("kubectl", "get", "pods", "-n", addon.Name,
					"-o", "jsonpath={range .items[*]}{.metadata.name}={.status.phase}{','}{end}").Output()
			}
			for _, entry := range strings.Split(string(output), ",") {
				parts := strings.SplitN(entry, "=", 2)
				if len(parts) == 2 && parts[0] != "" {
					isRunning := parts[1] == "Running"
					info.Props = append(info.Props, AddonStatusProp{
						Name:  parts[0],
						Value: parts[1],
						Okay:  &isRunning,
					})
				}
			}
		}

		result.Addons = append(result.Addons, info)
	}

	return result, nil
}

func (p *linuxAddonProvider) Export(_ AddonExportConfig) error {
	return NotSupportedError("addons export",
		"addon export on Linux hosts is not yet implemented")
}

func (p *linuxAddonProvider) Import(_ AddonImportConfig) error {
	return NotSupportedError("addons import",
		"addon import on Linux hosts is not yet implemented")
}

func (p *linuxAddonProvider) RunCommand(cfg AddonRunCommandConfig) error {
	switch cfg.CommandName {
	case "enable":
		return p.Enable(AddonEnableConfig{Name: cfg.AddonName, ShowOutput: cfg.ShowOutput})
	case "disable":
		return p.Disable(AddonDisableConfig{Name: cfg.AddonName, ShowOutput: cfg.ShowOutput})
	default:
		return NotSupportedError(fmt.Sprintf("addon %s", cfg.CommandName),
			fmt.Sprintf("addon '%s' command on Linux hosts is not yet implemented", cfg.CommandName))
	}
}

func (p *linuxAddonProvider) addAddonToConfig(addonName string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var addons []any
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			addons = append(addons, list...)
		}
	}

	exists := false
	for _, a := range addons {
		if m, ok := a.(map[string]any); ok {
			if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
				exists = true
				break
			}
		}
	}
	if !exists {
		addons = append(addons, map[string]any{
			"Name":           addonName,
			"Implementation": "",
		})
	}

	(*cfgMap)["EnabledAddons"] = addons
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeAddonFromConfig(addonName string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var addons []any
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			for _, a := range list {
				if m, ok := a.(map[string]any); ok {
					if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
						continue
					}
				}
				addons = append(addons, a)
			}
		}
	}

	(*cfgMap)["EnabledAddons"] = addons
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) addRegistryToConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			registries = append(registries, list...)
		}
	}

	exists := false
	for _, r := range registries {
		if s, ok := r.(string); ok && s == registry {
			exists = true
			break
		}
	}
	if !exists {
		registries = append(registries, registry)
	}

	(*cfgMap)["Registries"] = registries
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeRegistryFromConfig(registry string) error {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("loading setup config: %w", err)
	}

	var registries []any
	if rawRegs, ok := (*cfgMap)["Registries"]; ok && rawRegs != nil {
		if list, ok := rawRegs.([]any); ok {
			for _, r := range list {
				if s, ok := r.(string); ok && s == registry {
					continue
				}
				registries = append(registries, r)
			}
		}
	}

	(*cfgMap)["Registries"] = registries
	return kjson.ToFile(configPath, cfgMap)
}

func ensureHostEntry(hostname, ip string) {
	content, err := os.ReadFile("/etc/hosts")
	if err == nil {
		if strings.Contains(string(content), hostname) {
			return
		}
	}
	entry := fmt.Sprintf("\n%s %s\n", ip, hostname)
	f, err := os.OpenFile("/etc/hosts", os.O_APPEND|os.O_WRONLY, 0644)
	if err == nil {
		defer f.Close()
		_, _ = f.WriteString(entry)
	} else {
		cmd := exec.Command("sudo", "sh", "-c", fmt.Sprintf("printf '%%s' '%s' >> /etc/hosts", entry))
		_ = cmd.Run()
	}
}

func (p *linuxAddonProvider) isAddonEnabledInConfig(addonName string) bool {
	configDir := p.configDir
	if configDir == "" {
		configDir = host.K2sConfigDir()
	}
	configPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	cfgMap, err := kjson.FromFile[map[string]any](configPath)
	if err != nil {
		return false
	}
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			for _, a := range list {
				if m, ok := a.(map[string]any); ok {
					if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
						return true
					}
				}
			}
		}
	}
	return false
}

// isAddonDeployed checks if an addon has any pods deployed in the cluster.
func isAddonDeployed(addonName string) bool {
	ctx, cancel := context.WithTimeout(context.Background(), defaultKubeTimeout)
	defer cancel()

	output, err := exec.CommandContext(ctx, "kubectl", "get", "pods", "-A",
		"-l", fmt.Sprintf("app.kubernetes.io/name=%s", addonName),
		"-o", "jsonpath={.items}").Output()
	if err == nil && len(strings.TrimSpace(string(output))) > 2 {
		return true
	}

	output, err = exec.CommandContext(ctx, "kubectl", "get", "pods", "-A",
		"-l", fmt.Sprintf("app=%s", addonName),
		"-o", "jsonpath={.items}").Output()
	if err == nil && len(strings.TrimSpace(string(output))) > 2 {
		return true
	}

	output, err = exec.CommandContext(ctx, "kubectl", "get", "pods", "-n", addonName,
		"-o", "jsonpath={.items}").Output()
	if err == nil && len(strings.TrimSpace(string(output))) > 2 {
		return true
	}

	return false
}
