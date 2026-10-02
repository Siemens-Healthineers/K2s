// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
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

func init() {
	if os.Getenv("KUBECONFIG") == "" {
		if _, err := os.Stat("/etc/kubernetes/admin.conf"); err == nil {
			_ = os.Setenv("KUBECONFIG", "/etc/kubernetes/admin.conf")
		}
	}
}

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
	slog.Info("[Addon] Enabling addon", "name", cfg.Name, "implementation", cfg.Implementation)

	if cfg.Name == "registry" {
		return p.enableRegistry(cfg)
	}
	if cfg.Name == "ingress" {
		return p.enableIngress(cfg)
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

	ingressType := cfg.Params["ingress"]
	if ingressType != "" && ingressType != "nginx" {
		return fmt.Errorf("ingress implementation '%s' is not supported on Linux hosts", ingressType)
	}

	if ingressType == "nginx" {
		if !p.isAddonEnabledInConfig("ingress", "nginx") {
			if err := p.enableIngress(AddonEnableConfig{Name: "ingress", Implementation: "nginx", ShowOutput: cfg.ShowOutput}); err != nil {
				slog.Warn("[Addon] Failed to enable ingress nginx for registry", "error", err)
			}
		}
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

	hasIngress := ingressType == "nginx" || p.isAddonEnabledInConfig("ingress")
	if hasIngress {
		regIngressDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx")
		if _, err := os.Stat(regIngressDir); err == nil {
			_ = exec.Command("kubectl", "apply", "-k", regIngressDir).Run()
		}
	}

	// 6. Ensure /etc/hosts has k2s.registry.local pointing to node IP
	nodeIP := getNodeIP()
	if nodeIP != "" && nodeIP != "127.0.0.1" {
		setHostEntry("k2s.registry.local", nodeIP)
	} else {
		setHostEntry("k2s.registry.local", "127.0.0.1")
	}

	// 7. Add registry via Add-Registry.sh
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
		if hasIngress {
			_ = exec.Command(addRegScript, "--registry", "k2s.registry.local", "--plain-http").Run()
		}
	}

	// 8. Update setup.json
	_ = p.addAddonToConfig("registry", "")
	if hasIngress {
		_ = p.addRegistryToConfig("k2s.registry.local")
	} else {
		_ = p.addRegistryToConfig("k2s.registry.local:30500")
	}

	return nil
}

func (p *linuxAddonProvider) enableIngress(cfg AddonEnableConfig) error {
	impl := cfg.Implementation
	if impl == "" {
		impl = "nginx"
	}

	if p.isAddonEnabledInConfig("ingress", impl) {
		return fmt.Errorf("addon 'ingress %s' is already enabled, nothing to do", impl)
	}

	if impl != "nginx" {
		return fmt.Errorf("ingress implementation '%s' is not supported on Linux hosts", impl)
	}

	// 1. Create ingress-nginx namespace
	_ = exec.Command("kubectl", "create", "namespace", "ingress-nginx").Run()

	// 2. Apply ingress-nginx manifests
	manifestFile := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "ingress-nginx.yaml")
	if _, err := os.Stat(manifestFile); err != nil {
		return fmt.Errorf("ingress manifest not found: %s", manifestFile)
	}

	cmd := exec.Command("kubectl", "apply", "-f", manifestFile)
	if cfg.ShowOutput {
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stderr
	}
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("kubectl apply ingress-nginx failed: %w", err)
	}

	// 3. Patch externalIPs on service/ingress-nginx-controller
	nodeIP := getNodeIP()
	if nodeIP != "" && nodeIP != "127.0.0.1" {
		patchJson := fmt.Sprintf(`{"spec":{"externalIPs":["%s"]}}`, nodeIP)
		_ = exec.Command("kubectl", "patch", "svc", "ingress-nginx-controller", "-n", "ingress-nginx", "-p", patchJson).Run()
	}

	// 4. Wait for controller rollout
	rolloutCmd := exec.Command("kubectl", "rollout", "status", "deployment/ingress-nginx-controller", "-n", "ingress-nginx", "--timeout=180s")
	if cfg.ShowOutput {
		rolloutCmd.Stdout = os.Stdout
		rolloutCmd.Stderr = os.Stderr
	}
	if err := rolloutCmd.Run(); err != nil {
		return fmt.Errorf("ingress controller rollout failed: %w", err)
	}

	// 5. Apply cluster-local-ingress.yaml
	clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "cluster-local-ingress.yaml")
	if _, err := os.Stat(clusterLocal); err == nil {
		_ = exec.Command("kubectl", "apply", "-f", clusterLocal).Run()
	}

	if nodeIP != "" && nodeIP != "127.0.0.1" {
		setHostEntry("k2s.cluster.local", nodeIP)
	} else {
		setHostEntry("k2s.cluster.local", "127.0.0.1")
	}

	// 6. Update setup.json
	_ = p.addAddonToConfig("ingress", impl)

	return nil
}

func (p *linuxAddonProvider) Disable(cfg AddonDisableConfig) error {
	slog.Info("[Addon] Disabling addon", "name", cfg.Name, "implementation", cfg.Implementation)

	if cfg.Name == "registry" {
		return p.disableRegistry(cfg)
	}
	if cfg.Name == "ingress" {
		return p.disableIngress(cfg)
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

	regIngressDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "ingress-nginx")
	if _, err := os.Stat(regIngressDir); err == nil {
		_ = exec.Command("kubectl", "delete", "-k", regIngressDir, "--ignore-not-found").Run()
	}

	registryManifestsDir := filepath.Join(p.installDir, "addons", "registry", "manifests", "registry")
	delCmd := exec.Command("kubectl", "delete", "-k", registryManifestsDir, "--ignore-not-found")
	if cfg.ShowOutput {
		delCmd.Stdout = os.Stdout
		delCmd.Stderr = os.Stderr
	}
	_ = delCmd.Run()

	_ = exec.Command("kubectl", "delete", "namespace", "registry", "--ignore-not-found").Run()

	if cfg.Params != nil && (cfg.Params["deleteimages"] == "true" || cfg.Params["delete-images"] == "true" || cfg.Params["d"] == "true") {
		_ = exec.Command("sudo", "rm", "-rf", "/registry").Run()
	}

	// Remove host entry from /etc/hosts
	removeHostEntry("k2s.registry.local")

	// Remove registries via Remove-Registry.sh
	rmRegScript := filepath.Join(p.installDir, "lib", "scripts", "linux", "debian", "host", "image", "registry", "Remove-Registry.sh")
	if _, err := os.Stat(rmRegScript); err == nil {
		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local:30500").Run()
		_ = exec.Command(rmRegScript, "--registry", "k2s.registry.local").Run()
	}

	// Update setup.json
	_ = p.removeAddonFromConfig("registry", "")
	_ = p.removeRegistryFromConfig("k2s.registry.local:30500")
	_ = p.removeRegistryFromConfig("k2s.registry.local")

	return nil
}

func (p *linuxAddonProvider) disableIngress(cfg AddonDisableConfig) error {
	impl := cfg.Implementation
	if impl == "" {
		impl = "nginx"
	}

	if !p.isAddonEnabledInConfig("ingress", impl) && !isAddonDeployed("ingress-nginx") {
		return fmt.Errorf("addon 'ingress %s' is already disabled, nothing to do", impl)
	}

	removeHostEntry("k2s.cluster.local")

	clusterLocal := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "cluster-local-ingress.yaml")
	if _, err := os.Stat(clusterLocal); err == nil {
		_ = exec.Command("kubectl", "delete", "-f", clusterLocal, "--ignore-not-found").Run()
	}

	manifestFile := filepath.Join(p.installDir, "addons", "ingress", "nginx", "manifests", "ingress-nginx.yaml")
	if _, err := os.Stat(manifestFile); err == nil {
		delCmd := exec.Command("kubectl", "delete", "-f", manifestFile, "--ignore-not-found")
		if cfg.ShowOutput {
			delCmd.Stdout = os.Stdout
			delCmd.Stderr = os.Stderr
		}
		_ = delCmd.Run()
	}

	_ = exec.Command("kubectl", "delete", "namespace", "ingress-nginx", "--ignore-not-found").Run()

	_ = p.removeAddonFromConfig("ingress", impl)

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
			if addon.Name == "registry" {
				podRunning := false
				out, err := exec.Command("kubectl", "get", "statefulset", "registry", "-n", "registry", "-o", "jsonpath={.status.readyReplicas}").Output()
				if err == nil && strings.TrimSpace(string(out)) != "" && strings.TrimSpace(string(out)) != "0" {
					podRunning = true
				}
				msgPod := "The registry pod is not working"
				if podRunning {
					msgPod = "The registry pod is working"
				}
				info.Props = append(info.Props, AddonStatusProp{
					Name:    "IsRegistryPodRunning",
					Value:   podRunning,
					Okay:    &podRunning,
					Message: &msgPod,
				})

				reachable := false
				regHost := "k2s.registry.local:30500"
				client := &http.Client{
					Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}},
					Timeout:   5 * time.Second,
				}
				for _, u := range []string{"http://k2s.registry.local:30500/v2/", "https://k2s.registry.local/v2/", "http://127.0.0.1:30500/v2/"} {
					resp, err := client.Get(u)
					if err == nil && (resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusUnauthorized) {
						reachable = true
						regHost = strings.TrimPrefix(strings.TrimPrefix(strings.TrimSuffix(u, "/v2/"), "http://"), "https://")
						resp.Body.Close()
						break
					}
				}
				msgReach := "The registry is not reachable"
				if reachable {
					msgReach = fmt.Sprintf("The registry '%s' is reachable", regHost)
				}
				info.Props = append(info.Props, AddonStatusProp{
					Name:    "IsRegistryReachable",
					Value:   reachable,
					Okay:    &reachable,
					Message: &msgReach,
				})
			} else if addon.Name == "ingress" {
				controllerRunning := false
				out, err := exec.Command("kubectl", "get", "deployment", "ingress-nginx-controller", "-n", "ingress-nginx", "-o", "jsonpath={.status.readyReplicas}").Output()
				if err == nil && strings.TrimSpace(string(out)) != "" && strings.TrimSpace(string(out)) != "0" {
					controllerRunning = true
				}
				msgController := "The nginx ingress controller is not working"
				if controllerRunning {
					msgController = "The nginx ingress controller is working"
				}
				info.Props = append(info.Props, AddonStatusProp{
					Name:    "IsIngressNginxRunning",
					Value:   controllerRunning,
					Okay:    &controllerRunning,
					Message: &msgController,
				})
			} else {
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
	params := parsePsParams(cfg.Params)
	switch cfg.CommandName {
	case "enable":
		return p.Enable(AddonEnableConfig{
			Name:           cfg.AddonName,
			Implementation: cfg.Implementation,
			Params:         params,
			ShowOutput:     cfg.ShowOutput,
		})
	case "disable":
		return p.Disable(AddonDisableConfig{
			Name:           cfg.AddonName,
			Implementation: cfg.Implementation,
			Params:         params,
			ShowOutput:     cfg.ShowOutput,
		})
	default:
		return NotSupportedError(fmt.Sprintf("addon %s", cfg.CommandName),
			fmt.Sprintf("addon '%s' command on Linux hosts is not yet implemented", cfg.CommandName))
	}
}

func parsePsParams(params []string) map[string]string {
	m := make(map[string]string)
	for i := 0; i < len(params); i++ {
		p := strings.TrimSpace(params[i])
		if !strings.HasPrefix(p, "-") {
			continue
		}
		p = strings.TrimPrefix(p, "-")

		// Case 1: "-Key Value" (space-separated in single entry)
		if spaceIdx := strings.Index(p, " "); spaceIdx != -1 {
			key := strings.ToLower(strings.TrimSpace(p[:spaceIdx]))
			val := strings.Trim(strings.TrimSpace(p[spaceIdx+1:]), "'\"")
			m[key] = val
			continue
		}

		// Case 2: "-Key:Value"
		if colonIdx := strings.Index(p, ":"); colonIdx != -1 {
			key := strings.ToLower(strings.TrimSpace(p[:colonIdx]))
			val := strings.Trim(strings.TrimSpace(p[colonIdx+1:]), "'\"")
			m[key] = val
			continue
		}

		// Case 3: "-Key" followed by "Value" in next element
		key := strings.ToLower(strings.TrimSpace(p))
		if i+1 < len(params) && !strings.HasPrefix(strings.TrimSpace(params[i+1]), "-") {
			m[key] = strings.Trim(strings.TrimSpace(params[i+1]), "'\"")
			i++
		} else {
			// Case 4: Boolean flag
			m[key] = "true"
		}
	}
	return m
}

func (p *linuxAddonProvider) addAddonToConfig(addonName string, impl ...string) error {
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

	implementation := ""
	if len(impl) > 0 {
		implementation = impl[0]
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
				if implementation == "" {
					exists = true
					break
				}
				if im, ok := m["Implementation"].(string); ok && strings.EqualFold(im, implementation) {
					exists = true
					break
				}
			}
		}
	}
	if !exists {
		addons = append(addons, map[string]any{
			"Name":           addonName,
			"Implementation": implementation,
		})
	}

	(*cfgMap)["EnabledAddons"] = addons
	return kjson.ToFile(configPath, cfgMap)
}

func (p *linuxAddonProvider) removeAddonFromConfig(addonName string, impl ...string) error {
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

	implementation := ""
	if len(impl) > 0 {
		implementation = impl[0]
	}

	var addons []any
	if rawAddons, ok := (*cfgMap)["EnabledAddons"]; ok && rawAddons != nil {
		if list, ok := rawAddons.([]any); ok {
			for _, a := range list {
				if m, ok := a.(map[string]any); ok {
					if n, ok := m["Name"].(string); ok && strings.EqualFold(n, addonName) {
						if implementation != "" {
							if im, ok := m["Implementation"].(string); ok && strings.EqualFold(im, implementation) {
								continue
							}
						} else {
							continue
						}
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

func setHostEntry(hostname, ip string) {
	content, err := os.ReadFile("/etc/hosts")
	if err != nil {
		return
	}
	lines := strings.Split(string(content), "\n")
	var newLines []string
	found := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			newLines = append(newLines, line)
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) >= 2 {
			hasHost := false
			for _, f := range fields[1:] {
				if f == hostname {
					hasHost = true
					break
				}
			}
			if hasHost {
				newLines = append(newLines, fmt.Sprintf("%s %s", ip, hostname))
				found = true
				continue
			}
		}
		newLines = append(newLines, line)
	}
	if !found {
		newLines = append(newLines, fmt.Sprintf("%s %s", ip, hostname))
	}
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0644); err != nil {
		cmd := exec.Command("sudo", "sh", "-c", fmt.Sprintf("printf '%%s\n' %q > /etc/hosts", newContent))
		_ = cmd.Run()
	}
}

func removeHostEntry(hostname string) {
	content, err := os.ReadFile("/etc/hosts")
	if err != nil {
		return
	}
	lines := strings.Split(string(content), "\n")
	var newLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			newLines = append(newLines, line)
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) >= 2 {
			hasHost := false
			for _, f := range fields[1:] {
				if f == hostname {
					hasHost = true
					break
				}
			}
			if hasHost {
				continue
			}
		}
		newLines = append(newLines, line)
	}
	newContent := strings.Join(newLines, "\n")
	if err := os.WriteFile("/etc/hosts", []byte(newContent), 0644); err != nil {
		cmd := exec.Command("sudo", "sh", "-c", fmt.Sprintf("printf '%%s\n' %q > /etc/hosts", newContent))
		_ = cmd.Run()
	}
}

func getNodeIP() string {
	out, err := exec.Command("kubectl", "get", "nodes", "-o", "jsonpath={.items[0].status.addresses[?(@.type==\"InternalIP\")].address}").Output()
	if err == nil && len(strings.TrimSpace(string(out))) > 0 {
		return strings.TrimSpace(string(out))
	}
	return "127.0.0.1"
}

func (p *linuxAddonProvider) isAddonEnabledInConfig(addonName string, impl ...string) bool {
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
						if len(impl) > 0 && impl[0] != "" {
							if im, ok := m["Implementation"].(string); ok && !strings.EqualFold(im, impl[0]) {
								continue
							}
						}
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

	namespaces := []string{addonName}
	if addonName == "ingress" {
		namespaces = append(namespaces, "ingress-nginx")
	}

	for _, ns := range namespaces {
		output, err := exec.CommandContext(ctx, "kubectl", "get", "pods", "-n", ns,
			"-o", "jsonpath={.items}").Output()
		if err == nil && len(strings.TrimSpace(string(output))) > 2 {
			return true
		}
	}

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

	return false
}
