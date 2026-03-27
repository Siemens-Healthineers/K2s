// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

type linuxAddonProvider struct {
	installDir string
}

func newLinuxAddonProvider(cfg ProviderConfig) *linuxAddonProvider {
	return &linuxAddonProvider{installDir: cfg.InstallDir}
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

func (p *linuxAddonProvider) Disable(cfg AddonDisableConfig) error {
	slog.Info("[Addon] Disabling addon", "name", cfg.Name)

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
			if err == nil {
				for _, entry := range strings.Split(string(output), ",") {
					parts := strings.SplitN(entry, "=", 2)
					if len(parts) == 2 {
						info.Props = append(info.Props, AddonStatusProp{
							Name:  parts[0],
							Value: parts[1],
							Okay:  parts[1] == "Running",
						})
					}
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

// isAddonDeployed checks if an addon has any pods deployed in the cluster.
func isAddonDeployed(addonName string) bool {
	output, err := exec.Command("kubectl", "get", "pods", "-A",
		"-l", fmt.Sprintf("app.kubernetes.io/name=%s", addonName),
		"-o", "jsonpath={.items}").Output()
	if err != nil {
		return false
	}
	return len(strings.TrimSpace(string(output))) > 2 // "[]" = empty
}
