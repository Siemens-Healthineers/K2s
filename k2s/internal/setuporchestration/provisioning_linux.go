// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"bufio"
	"fmt"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/config"
)

const (
	crioServiceName = "crio"
	crioSocket      = "unix:///var/run/crio/crio.sock"
	localProxyURL   = "http://127.0.0.1:8181"
	proxyService    = "k2s-httpproxy"
	proxyNetworkSvc = "k2s-proxy-network"
	proxyNetworkDev = "k2s-proxy0"
)

var k8sVersionPattern = regexp.MustCompile(`(?m)return\s+['\"](v[0-9]+\.[0-9]+\.[0-9]+)['\"]`)

func (o *LinuxOrchestrator) checkHostPrerequisites(_ InstallConfig) error {
	slog.Info("[Install] Checking Linux host prerequisites")

	if os.Geteuid() != 0 {
		return fmt.Errorf("Linux installation must be run as root (for example: sudo ./k2s install --linux-only)")
	}

	if err := requireDebian13(); err != nil {
		return err
	}

	for _, bin := range []string{"systemctl", "apt-get", "dpkg", "modprobe", "sysctl"} {
		if _, err := exec.LookPath(bin); err != nil {
			return fmt.Errorf("required host tool %q was not found in PATH: %w", bin, err)
		}
	}

	if err := runCommand("systemctl", "is-system-running", "--wait"); err != nil {
		slog.Warn("[Install] systemd is not fully running; continuing because package provisioning may finish pending startup work", "error", err)
	}

	if swapEnabled() {
		return fmt.Errorf("swap is enabled; disable swap before installing K2s")
	}

	for _, mod := range []string{"br_netfilter", "overlay"} {
		if err := runCommand("modprobe", mod); err != nil {
			return fmt.Errorf("required kernel module %q could not be loaded: %w", mod, err)
		}
	}

	for key, value := range map[string]string{
		"net.bridge.bridge-nf-call-iptables":  "1",
		"net.bridge.bridge-nf-call-ip6tables": "1",
		"net.ipv4.ip_forward":                 "1",
	} {
		if err := runCommand("sysctl", "-w", key+"="+value); err != nil {
			return fmt.Errorf("could not configure required sysctl %q: %w", key, err)
		}
	}

	if _, err := os.Stat(kubeconfigSrc); err == nil {
		return fmt.Errorf("an existing Kubernetes control plane was found at %s; run 'k2s uninstall' before installing", kubeconfigSrc)
	}

	return nil
}

func (o *LinuxOrchestrator) provisionKubernetes(cfg InstallConfig) (string, error) {
	k8sVersion, err := resolveKubernetesVersion(cfg.InstallDir)
	if err != nil {
		return "", err
	}

	if err := o.installHTTPProxy(cfg); err != nil {
		return "", err
	}

	// setup.json is read by regular users for commands such as `k2s status`.
	// Keep the package cache private, but allow traversal of the state directory.
	if err := os.MkdirAll(cfg.ConfigDir, 0755); err != nil {
		return "", fmt.Errorf("create runtime config directory: %w", err)
	}
	if err := os.Chmod(cfg.ConfigDir, 0755); err != nil {
		return "", fmt.Errorf("set runtime config directory permissions: %w", err)
	}

	stagingDir := filepath.Join(cfg.ConfigDir, "packages")
	if err := os.MkdirAll(stagingDir, 0700); err != nil {
		return "", fmt.Errorf("create package staging directory: %w", err)
	}

	downloadScript := filepath.Join(cfg.InstallDir, "cfg", "nodeextension", "debian13", "scripts", "download-k8s-packages.sh")
	installScript := filepath.Join(cfg.InstallDir, "cfg", "nodeextension", "debian13", "scripts", "install-k8s-packages.sh")
	for _, script := range []string{downloadScript, installScript} {
		if _, err := os.Stat(script); err != nil {
			return "", fmt.Errorf("required Debian 13 provisioning script is missing at %s: %w", script, err)
		}
	}

	slog.Info("[Install] Downloading Kubernetes and CRI-O packages", "version", k8sVersion)
	if cfg.ShowLogs {
		slog.Info("[Install] Package staging directory", "path", stagingDir)
	}
	if err := runCommandWithLogs(cfg.ShowLogs, "bash", downloadScript, stagingDir, k8sVersion, localProxyURL); err != nil {
		return "", fmt.Errorf("download Kubernetes packages: %w", err)
	}

	registryToken, err := readRegistryToken(cfg.InstallDir)
	if err != nil {
		return "", err
	}

	slog.Info("[Install] Installing Kubernetes and CRI-O packages")
	if err := runCommandWithLogs(cfg.ShowLogs, "bash", installScript, stagingDir, localProxyURL, registryToken, "false", mergeNoProxy(cfg.NoProxy)); err != nil {
		return "", fmt.Errorf("install Kubernetes packages: %w", err)
	}

	if err := o.checkProvisionedRuntime(k8sVersion); err != nil {
		return "", err
	}

	return k8sVersion, nil
}

func (o *LinuxOrchestrator) checkProvisionedRuntime(k8sVersion string) error {
	for _, bin := range []string{"kubeadm", "kubelet", "kubectl", "crictl", "crio"} {
		if _, err := exec.LookPath(bin); err != nil {
			return fmt.Errorf("provisioning completed but required binary %q is unavailable: %w", bin, err)
		}
	}
	if err := runCommand("systemctl", "enable", "--now", crioServiceName); err != nil {
		return fmt.Errorf("enable and start CRI-O: %w", err)
	}
	if err := runCommand("crictl", "--runtime-endpoint", crioSocket, "version"); err != nil {
		return fmt.Errorf("CRI-O is not available through %s: %w", crioSocket, err)
	}

	versionOutput, err := runCommandOutput("kubeadm", "version", "-o", "short")
	if err != nil {
		return fmt.Errorf("read kubeadm version: %w", err)
	}
	if strings.TrimSpace(versionOutput) != k8sVersion {
		return fmt.Errorf("installed kubeadm version %q does not match required version %q", strings.TrimSpace(versionOutput), k8sVersion)
	}
	return nil
}

func (o *LinuxOrchestrator) installHTTPProxy(cfg InstallConfig) error {
	proxyBinary := filepath.Join(cfg.InstallDir, "bin", "httpproxy")
	if _, err := os.Stat(proxyBinary); err != nil {
		return fmt.Errorf("Linux httpproxy binary is missing at %s: %w", proxyBinary, err)
	}
	networkDependencies := ""
	if cfg.LinuxOnly {
		proxyNetwork, err := config.ReadKubeSwitchConfig(cfg.InstallDir)
		if err != nil {
			return fmt.Errorf("read KubeSwitch proxy configuration: %w", err)
		}
		if err := installLinuxOnlyProxyNetwork(proxyNetwork); err != nil {
			return err
		}
		networkDependencies = fmt.Sprintf("Requires=%s.service\nAfter=%s.service\n", proxyNetworkSvc, proxyNetworkSvc)
	}

	noProxy := mergeNoProxy(cfg.NoProxy)
	// Listen on all host interfaces so pods can reach the proxy through the
	// K2s-owned configured KubeSwitch compatibility gateway. Access remains
	// restricted to loopback, pod, and service CIDRs; it is not open to peers.
	args := []string{"--addr", ":8181", "--allowed-cidr", "127.0.0.0/8", "--allowed-cidr", podNetworkCIDR, "--allowed-cidr", servicesCIDR}
	if cfg.Proxy != "" {
		if _, err := url.ParseRequestURI(cfg.Proxy); err != nil {
			return fmt.Errorf("invalid --proxy value %q: %w", cfg.Proxy, err)
		}
		args = append(args, "--forwardproxy", cfg.Proxy)
	}

	unitPath := filepath.Join("/etc/systemd/system", proxyService+".service")
	unit := fmt.Sprintf(`[Unit]
Description=K2s local HTTP proxy
After=network-online.target
Wants=network-online.target
%s

[Service]
Type=simple
ExecStart=%s %s
Environment="NO_PROXY=%s"
Environment="no_proxy=%s"
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
`, networkDependencies, proxyBinary, strings.Join(args, " "), systemdValue(noProxy), systemdValue(noProxy))
	if err := os.WriteFile(unitPath, []byte(unit), 0644); err != nil {
		return fmt.Errorf("write local HTTP proxy service: %w", err)
	}
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd after HTTP proxy setup: %w", err)
	}
	if err := runCommand("systemctl", "enable", "--now", proxyService); err != nil {
		return fmt.Errorf("enable and start local HTTP proxy: %w", err)
	}
	return nil
}

func removeHTTPProxy(removeCompatibilityNetwork bool) {
	_ = runCommand("systemctl", "disable", "--now", proxyService)
	_ = os.Remove(filepath.Join("/etc/systemd/system", proxyService+".service"))
	if removeCompatibilityNetwork {
		removeLinuxOnlyProxyNetwork()
	}
	_ = runCommand("systemctl", "daemon-reload")
}

// installLinuxOnlyProxyNetwork publishes the established Windows-host proxy
// gateway address to pods on a native Linux-only host. The dedicated dummy
// interface avoids changing Flannel-owned cni0 while preserving the common
// workload-proxy endpoint from cfg/config.json across topologies.
func installLinuxOnlyProxyNetwork(proxyNetwork config.KubeSwitchConfig) error {
	exists, err := linuxProxyNetworkExists(proxyNetwork)
	if err != nil {
		return err
	}
	if !exists {
		if err := ensureProxyNetworkIsAvailable(proxyNetwork); err != nil {
			return err
		}
	}

	unitPath := filepath.Join("/etc/systemd/system", proxyNetworkSvc+".service")
	unit := fmt.Sprintf(`[Unit]
Description=K2s Linux-only proxy compatibility network
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -ec '/usr/sbin/ip link show %s >/dev/null 2>&1 || /usr/sbin/ip link add %s type dummy; /usr/sbin/ip addr replace %s dev %s; /usr/sbin/ip link set %s up'
ExecStop=/usr/sbin/ip link delete %s

[Install]
WantedBy=multi-user.target
`, proxyNetworkDev, proxyNetworkDev, proxyNetwork.CIDR, proxyNetworkDev, proxyNetworkDev, proxyNetworkDev)
	if err := os.WriteFile(unitPath, []byte(unit), 0644); err != nil {
		return fmt.Errorf("write proxy compatibility network service: %w", err)
	}
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd after proxy compatibility network setup: %w", err)
	}
	if err := runCommand("systemctl", "enable", "--now", proxyNetworkSvc); err != nil {
		return fmt.Errorf("enable and start proxy compatibility network: %w", err)
	}
	slog.Info("[Install] Linux-only pod proxy gateway configured", "address", proxyNetwork.Address, "interface", proxyNetworkDev)
	return nil
}

func removeLinuxOnlyProxyNetwork() {
	_ = runCommand("systemctl", "disable", "--now", proxyNetworkSvc)
	_ = os.Remove(filepath.Join("/etc/systemd/system", proxyNetworkSvc+".service"))
	_ = runCommand("ip", "link", "delete", proxyNetworkDev)
}

func linuxProxyNetworkExists(proxyNetwork config.KubeSwitchConfig) (bool, error) {
	output, err := runCommandOutput("ip", "-o", "-4", "addr", "show", "dev", proxyNetworkDev)
	if err != nil {
		return false, nil // Interface not found is the normal first-install state.
	}
	if !strings.Contains(output, proxyNetwork.CIDR) {
		return false, fmt.Errorf("existing interface %q does not own required configured KubeSwitch address %s; remove or correct it before installing K2s", proxyNetworkDev, proxyNetwork.CIDR)
	}
	return true, nil
}

func ensureProxyNetworkIsAvailable(proxyNetwork config.KubeSwitchConfig) error {
	addresses, err := runCommandOutput("ip", "-o", "-4", "addr", "show")
	if err != nil {
		return fmt.Errorf("inspect host addresses for proxy compatibility network: %w", err)
	}
	if strings.Contains(addresses, proxyNetwork.Address+"/") {
		return fmt.Errorf("configured KubeSwitch proxy address %s is already used by the host; remove the conflict before installing K2s", proxyNetwork.Address)
	}

	route, err := runCommandOutput("ip", "route", "show", proxyNetwork.CIDR)
	if err != nil {
		return fmt.Errorf("inspect host routes for proxy compatibility network: %w", err)
	}
	if strings.TrimSpace(route) != "" {
		return fmt.Errorf("configured KubeSwitch proxy network %s conflicts with existing route %q; remove the conflict before installing K2s", proxyNetwork.CIDR, strings.TrimSpace(route))
	}
	return nil
}

func resolveKubernetesVersion(installDir string) (string, error) {
	configPath := filepath.Join(installDir, "lib", "modules", "k2s", "k2s.infra.module", "config", "config.module.psm1")
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "", fmt.Errorf("read shared Kubernetes version from %s: %w", configPath, err)
	}
	match := k8sVersionPattern.FindStringSubmatch(string(data))
	if len(match) != 2 {
		return "", fmt.Errorf("could not find Get-DefaultK8sVersion value in %s", configPath)
	}
	return match[1], nil
}

func readRegistryToken(installDir string) (string, error) {
	path := filepath.Join(installDir, "bin", "registry.dat")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read packaged registry credentials from %s: %w", path, err)
	}
	value := strings.TrimSpace(string(data))
	if value == "" {
		return "", fmt.Errorf("packaged registry credentials at %s are empty", path)
	}
	return value, nil
}

func requireDebian13() error {
	file, err := os.Open("/etc/os-release")
	if err != nil {
		return fmt.Errorf("read /etc/os-release: %w", err)
	}
	defer file.Close()

	values := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		parts := strings.SplitN(scanner.Text(), "=", 2)
		if len(parts) == 2 {
			values[parts[0]] = strings.Trim(parts[1], "\"")
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("read /etc/os-release: %w", err)
	}
	if values["ID"] != "debian" || !strings.HasPrefix(values["VERSION_ID"], "13") {
		return fmt.Errorf("native Linux installation currently supports Debian 13 only; found %s %s", values["ID"], values["VERSION_ID"])
	}
	return nil
}

func swapEnabled() bool {
	data, err := os.ReadFile("/proc/swaps")
	if err != nil {
		return false
	}
	return len(strings.Fields(string(data))) > 5
}

func mergeNoProxy(entries []string) string {
	values := append([]string{}, entries...)
	values = append(values, "localhost", "127.0.0.1", "::1", podNetworkCIDR, servicesCIDR, ".svc", ".cluster.local")
	unique := map[string]struct{}{}
	for _, value := range values {
		value = strings.TrimSpace(value)
		if value != "" {
			unique[value] = struct{}{}
		}
	}
	result := make([]string, 0, len(unique))
	for value := range unique {
		result = append(result, value)
	}
	sort.Strings(result)
	return strings.Join(result, ",")
}

func systemdValue(value string) string {
	return strings.ReplaceAll(strings.ReplaceAll(value, "\\", "\\\\"), "\"", "\\\"")
}

func lookupUserID(value string) (int, error) {
	id, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("parse user ID %q: %w", value, err)
	}
	return id, nil
}
