// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/config"
)

const (
	crioServiceName       = "crio"
	crioSocket            = "unix:///var/run/crio/crio.sock"
	proxyService          = "k2s-httpproxy"
	proxyNetworkSvc       = "k2s-proxy-network"
	proxyNetworkDev       = "k2s-proxy0"
	proxyLogDir           = "/var/log/httpproxy"
	proxyLogFile          = "/var/log/httpproxy/httpproxy.log"
	kubeletLogDir         = "/var/log/kubelet"
	kubeletLogFile        = "/var/log/kubelet/kubelet.log"
	kubeletLogDropIn      = "/etc/systemd/system/kubelet.service.d/20-k2s-logging.conf"
	aptProxyConfig        = "/etc/apt/apt.conf.d/proxy.conf"
	criOProxyConfig       = "/etc/systemd/system/crio.service.d/http-proxy.conf"
	containersProxyConfig = "/etc/containers/containers.conf.d/20-k2s-proxy.conf"
	dnsProxyService       = "k2s-dnsproxy"
	dnsProxyConfig        = "/etc/k2s/dnsproxy.yaml"
	dnsProxyLogDir        = "/var/log/dnsproxy"
	dnsProxyLogFile       = "/var/log/dnsproxy/dnsproxy.log"
	resolverPath          = "/etc/resolv.conf"
	resolverStateFile     = "dns-resolver-state.json"
)

const aptProxyConfigHeader = "# Managed by K2s native Linux installation"
const resolverHeader = "# Managed by K2s native Linux installation; restored by k2s stop or uninstall"

var k8sVersionPattern = regexp.MustCompile(`(?m)return\s+['\"](v[0-9]+\.[0-9]+\.[0-9]+)['\"]`)

func (o *LinuxOrchestrator) checkHostPrerequisites(_ InstallConfig) error {
	slog.Info("[Install] Checking Linux host prerequisites")

	if os.Geteuid() != 0 {
		return fmt.Errorf("Linux installation must be run as root (for example: sudo ./k2s install --linux-only)")
	}

	if err := requireDebian13(); err != nil {
		return err
	}

	for _, bin := range []string{"systemctl", "apt-get", "dpkg", "modprobe", "sysctl", "chattr", "lsattr"} {
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

func (o *LinuxOrchestrator) provisionKubernetes(cfg InstallConfig, registryToken string) (string, error) {
	k8sVersion, err := resolveKubernetesVersion(cfg.InstallDir)
	if err != nil {
		return "", err
	}
	proxyURL, err := kubeSwitchProxyURL(cfg.InstallDir)
	if err != nil {
		return "", err
	}
	if err := o.installHTTPProxy(cfg); err != nil {
		return "", err
	}
	if err := configureAptProxy(proxyURL, cfg.ConfigDir); err != nil {
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
	if err := runCommandWithLogs(cfg.ShowLogs, "bash", downloadScript, stagingDir, k8sVersion, proxyURL); err != nil {
		return "", fmt.Errorf("download Kubernetes packages: %w", err)
	}

	slog.Info("[Install] Installing Kubernetes and CRI-O packages")
	if err := runCommandWithLogs(cfg.ShowLogs, "bash", installScript, stagingDir, proxyURL, registryToken, "false", mergeNoProxy(cfg.NoProxy)); err != nil {
		return "", fmt.Errorf("install Kubernetes packages: %w", err)
	}

	if err := o.checkProvisionedRuntime(k8sVersion); err != nil {
		return "", err
	}
	if err := configureKubeletFileLogging(); err != nil {
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
	proxyAllowedCIDRs := []string{"127.0.0.0/8", podNetworkCIDR, servicesCIDR}
	if cfg.LinuxOnly {
		proxyNetwork, err := config.ReadKubeSwitchConfig(cfg.InstallDir)
		if err != nil {
			return fmt.Errorf("read KubeSwitch proxy configuration: %w", err)
		}
		if err := installLinuxOnlyProxyNetwork(proxyNetwork); err != nil {
			return err
		}
		primaryHostIP, err := primaryHostIPv4()
		if err != nil {
			return fmt.Errorf("determine primary host address for local HTTP proxy access: %w", err)
		}
		networkDependencies = fmt.Sprintf("Requires=%s.service\nAfter=%s.service\n", proxyNetworkSvc, proxyNetworkSvc)
		// Permit pods through the configured KubeSwitch compatibility network
		// and this host only through its primary address. Do not allow the
		// complete primary network, which would expose the proxy to peers.
		proxyAllowedCIDRs = append(proxyAllowedCIDRs, proxyNetwork.CIDR)
		proxyAllowedCIDRs = append(proxyAllowedCIDRs, primaryHostIP+"/32")
		slog.Info("[Install] Permitting host access to KubeSwitch proxy endpoint", "address", primaryHostIP)
	}
	if err := ensureServiceLogFile(proxyLogDir, proxyLogFile); err != nil {
		return fmt.Errorf("prepare local HTTP proxy log file: %w", err)
	}

	noProxy := mergeNoProxy(cfg.NoProxy)
	// Listen on all host interfaces so pods can reach the proxy through the
	// K2s-owned configured KubeSwitch compatibility gateway. Access remains
	// restricted to loopback, pod, and service CIDRs; it is not open to peers.
	args := []string{"--addr", ":8181"}
	for _, cidr := range proxyAllowedCIDRs {
		args = append(args, "--allowed-cidr", cidr)
	}
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
StandardOutput=append:%s
StandardError=append:%s
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
`, networkDependencies, proxyBinary, strings.Join(args, " "), systemdValue(noProxy), systemdValue(noProxy), proxyLogFile, proxyLogFile)
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

func removeHTTPProxy(removeCompatibilityNetwork bool, configDir string) {
	_ = runCommand("systemctl", "disable", "--now", proxyService)
	_ = os.Remove(filepath.Join("/etc/systemd/system", proxyService+".service"))
	removeCriOProxyConfiguration()
	removeContainersProxyConfiguration()
	removeAptProxy(configDir)
	if removeCompatibilityNetwork {
		removeLinuxOnlyProxyNetwork()
	}
	_ = runCommand("systemctl", "daemon-reload")
}

type resolverState struct {
	Mode         os.FileMode `json:"mode"`
	LinkTarget   string      `json:"linkTarget,omitempty"`
	Content      []byte      `json:"content,omitempty"`
	WasImmutable bool        `json:"wasImmutable"`
}

// configureHostDNS makes Kubernetes DNS records available to all host
// applications. It only replaces /etc/resolv.conf while K2s is running and
// preserves the exact original file or symlink for stop/uninstall restoration.
func (o *LinuxOrchestrator) configureHostDNS(cfg InstallConfig) error {
	proxyNetwork, err := config.ReadKubeSwitchConfig(cfg.InstallDir)
	if err != nil {
		return fmt.Errorf("read KubeSwitch DNS configuration: %w", err)
	}
	upstreams, err := readResolverUpstreams()
	if err != nil {
		return err
	}
	if err := saveResolverState(cfg.ConfigDir); err != nil {
		return err
	}

	coreDNSIP, zones, err := discoverCoreDNS()
	if err != nil {
		removeDNSProxy(cfg.ConfigDir)
		return err
	}
	if err := writeDNSProxyConfig(proxyNetwork.Address, coreDNSIP, zones, upstreams); err != nil {
		removeDNSProxy(cfg.ConfigDir)
		return err
	}
	if err := startDNSProxy(cfg); err != nil {
		removeDNSProxy(cfg.ConfigDir)
		return err
	}
	if err := activateK2sResolver(); err != nil {
		removeDNSProxy(cfg.ConfigDir)
		return err
	}
	if err := verifyHostDNS(coreDNSIP, zones); err != nil {
		removeDNSProxy(cfg.ConfigDir)
		return err
	}
	return nil
}

func startDNSProxy(cfg InstallConfig) error {
	binary := filepath.Join(cfg.InstallDir, "bin", "dnsproxy")
	if _, err := os.Stat(binary); err != nil {
		return fmt.Errorf("Linux dnsproxy binary is missing at %s: %w", binary, err)
	}
	if err := ensureServiceLogFile(dnsProxyLogDir, dnsProxyLogFile); err != nil {
		return fmt.Errorf("prepare DNS proxy log file: %w", err)
	}
	unit := fmt.Sprintf(`[Unit]
Description=K2s DNS proxy
After=network-online.target kubelet.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=%s --config-path=%s
StandardOutput=append:%s
StandardError=append:%s
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
`, binary, dnsProxyConfig, dnsProxyLogFile, dnsProxyLogFile)
	unitPath := filepath.Join("/etc/systemd/system", dnsProxyService+".service")
	if err := os.WriteFile(unitPath, []byte(unit), 0644); err != nil {
		return fmt.Errorf("write DNS proxy service: %w", err)
	}
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd after DNS proxy setup: %w", err)
	}
	if err := runCommand("systemctl", "enable", "--now", dnsProxyService); err != nil {
		return fmt.Errorf("enable and start DNS proxy: %w", err)
	}
	if err := waitForDNSProxy(); err != nil {
		return err
	}
	return nil
}

func waitForDNSProxy() error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if err := runCommand("systemctl", "is-active", "--quiet", dnsProxyService); err == nil {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	status, statusErr := runCommandOutput("systemctl", "status", dnsProxyService, "--no-pager", "--full")
	if statusErr != nil {
		return fmt.Errorf("DNS proxy did not become active; systemd status: %s", statusErr)
	}
	return fmt.Errorf("DNS proxy did not become active; systemd status: %s", strings.TrimSpace(status))
}

func stopHostDNS(configDir string) error {
	if err := restoreResolverState(configDir); err != nil {
		return err
	}
	if err := runCommand("systemctl", "stop", dnsProxyService); err != nil {
		return fmt.Errorf("stop DNS proxy: %w", err)
	}
	return nil
}

func removeDNSProxy(configDir string) {
	if err := restoreResolverState(configDir); err != nil {
		slog.Warn("[Uninstall] Could not restore host resolver", "error", err)
	}
	if _, err := os.Stat(filepath.Join("/etc/systemd/system", dnsProxyService+".service")); err == nil {
		_ = runCommand("systemctl", "disable", "--now", dnsProxyService)
	}
	_ = os.Remove(filepath.Join("/etc/systemd/system", dnsProxyService+".service"))
	_ = os.Remove(dnsProxyConfig)
	_ = os.Remove(filepath.Join(configDir, resolverStateFile))
	_ = runCommand("systemctl", "daemon-reload")
}

func readResolverUpstreams() ([]string, error) {
	data, err := os.ReadFile(resolverPath)
	if err != nil {
		return nil, fmt.Errorf("read existing resolver configuration: %w", err)
	}
	var upstreams []string
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "nameserver" && net.ParseIP(fields[1]) != nil {
			upstreams = append(upstreams, fields[1])
		}
	}
	if len(upstreams) == 0 {
		return nil, fmt.Errorf("no nameserver entries found in %s", resolverPath)
	}
	return upstreams, nil
}

func saveResolverState(configDir string) error {
	info, err := os.Lstat(resolverPath)
	if err != nil {
		return fmt.Errorf("inspect existing resolver configuration: %w", err)
	}
	immutable, err := resolverIsImmutable()
	if err != nil {
		return err
	}
	state := resolverState{Mode: info.Mode(), WasImmutable: immutable}
	if info.Mode()&os.ModeSymlink != 0 {
		state.LinkTarget, err = os.Readlink(resolverPath)
		if err != nil {
			return fmt.Errorf("read resolver symlink: %w", err)
		}
	} else {
		state.Content, err = os.ReadFile(resolverPath)
		if err != nil {
			return fmt.Errorf("read resolver configuration: %w", err)
		}
	}
	data, err := json.Marshal(state)
	if err != nil {
		return fmt.Errorf("serialize resolver state: %w", err)
	}
	if err := os.MkdirAll(configDir, 0700); err != nil {
		return fmt.Errorf("create resolver state directory: %w", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, resolverStateFile), data, 0600); err != nil {
		return fmt.Errorf("save resolver state: %w", err)
	}
	return nil
}

func resolverIsImmutable() (bool, error) {
	output, err := runCommandOutput("lsattr", "-d", resolverPath)
	if err != nil {
		return false, fmt.Errorf("inspect immutable attribute on %s: %w", resolverPath, err)
	}
	return resolverIsImmutableFromOutput(output)
}

func resolverIsImmutableFromOutput(output string) (bool, error) {
	fields := strings.Fields(output)
	if len(fields) == 0 {
		return false, fmt.Errorf("no immutable attribute output for %s", resolverPath)
	}
	return strings.Contains(fields[0], "i"), nil
}

func activateK2sResolver() error {
	if err := setResolverImmutable(false); err != nil {
		return err
	}
	if err := os.Remove(resolverPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove existing resolver configuration: %w", err)
	}
	content := []byte(resolverHeader + "\nnameserver 127.0.0.1\n")
	if err := os.WriteFile(resolverPath, content, 0644); err != nil {
		return fmt.Errorf("write K2s resolver configuration: %w", err)
	}
	return nil
}

func restoreResolverState(configDir string) error {
	data, err := os.ReadFile(filepath.Join(configDir, resolverStateFile))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read saved resolver state: %w", err)
	}
	var state resolverState
	if err := json.Unmarshal(data, &state); err != nil {
		return fmt.Errorf("parse saved resolver state: %w", err)
	}
	current, err := os.ReadFile(resolverPath)
	if err != nil {
		return fmt.Errorf("read current resolver configuration: %w", err)
	}
	if !strings.HasPrefix(string(current), resolverHeader) {
		// DNS setup can fail before K2s takes ownership of resolv.conf. In that
		// case the original resolver is already intact and must not be touched.
		return nil
	}
	if err := setResolverImmutable(false); err != nil {
		return err
	}
	if err := os.Remove(resolverPath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove K2s resolver configuration: %w", err)
	}
	if state.LinkTarget != "" {
		if err := os.Symlink(state.LinkTarget, resolverPath); err != nil {
			return fmt.Errorf("restore resolver symlink: %w", err)
		}
	} else if err := os.WriteFile(resolverPath, state.Content, state.Mode.Perm()); err != nil {
		return fmt.Errorf("restore resolver configuration: %w", err)
	}
	if state.WasImmutable {
		if err := setResolverImmutable(true); err != nil {
			return err
		}
	}
	return nil
}

func setResolverImmutable(immutable bool) error {
	current, err := resolverIsImmutable()
	if err != nil {
		return err
	}
	if current == immutable {
		return nil
	}
	flag := "-i"
	operation := "clear"
	if immutable {
		flag = "+i"
		operation = "restore"
	}
	if err := runCommand("chattr", flag, resolverPath); err != nil {
		return fmt.Errorf("%s immutable attribute on %s: %w", operation, resolverPath, err)
	}
	return nil
}

func discoverCoreDNS() (string, []string, error) {
	serviceIP, err := runCommandOutput("kubectl", "--kubeconfig", kubeconfigSrc, "-n", "kube-system", "get", "service", "kube-dns", "-o", "jsonpath={.spec.clusterIP}")
	if err != nil {
		return "", nil, fmt.Errorf("discover kube-dns service: %w", err)
	}
	serviceIP = strings.TrimSpace(serviceIP)
	if net.ParseIP(serviceIP) == nil {
		return "", nil, fmt.Errorf("kube-dns service has invalid ClusterIP %q", serviceIP)
	}
	if err := runCommand("kubectl", "--kubeconfig", kubeconfigSrc, "-n", "kube-system", "rollout", "status", "deployment/coredns", "--timeout=120s"); err != nil {
		return "", nil, fmt.Errorf("wait for CoreDNS: %w", err)
	}
	corefile, err := runCommandOutput("kubectl", "--kubeconfig", kubeconfigSrc, "-n", "kube-system", "get", "configmap", "coredns", "-o", "jsonpath={.data.Corefile}")
	if err != nil {
		return "", nil, fmt.Errorf("read CoreDNS configuration: %w", err)
	}
	zones := coreDNSZones(corefile)
	if len(zones) == 0 {
		return "", nil, fmt.Errorf("no Kubernetes zones found in CoreDNS configuration")
	}
	return serviceIP, zones, nil
}

func coreDNSZones(corefile string) []string {
	seen := map[string]bool{}
	var zones []string
	for _, line := range strings.Split(corefile, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 || fields[0] != "kubernetes" {
			continue
		}
		for _, zone := range fields[1:] {
			if zone == "{" || zone == "." || strings.Contains(zone, "{") {
				break
			}
			zone = strings.TrimSuffix(zone, ".")
			if zone != "" && !seen[zone] {
				seen[zone] = true
				zones = append(zones, zone)
			}
		}
	}
	return zones
}

func writeDNSProxyConfig(kubeSwitchAddress string, coreDNSIP string, zones []string, upstreams []string) error {
	var builder strings.Builder
	builder.WriteString("---\nlisten-addrs:\n  - \"127.0.0.1\"\n")
	builder.WriteString(fmt.Sprintf("  - \"%s\"\n", kubeSwitchAddress))
	builder.WriteString("listen-ports:\n  - 53\n")
	builder.WriteString("upstream:\n")
	for _, zone := range zones {
		builder.WriteString(fmt.Sprintf("  - \"[/%s/]%s\"\n", zone, coreDNSIP))
	}
	for _, upstream := range upstreams {
		builder.WriteString(fmt.Sprintf("  - \"%s\"\n", upstream))
	}
	if err := os.MkdirAll(filepath.Dir(dnsProxyConfig), 0755); err != nil {
		return fmt.Errorf("create DNS proxy configuration directory: %w", err)
	}
	if err := os.WriteFile(dnsProxyConfig, []byte(builder.String()), 0644); err != nil {
		return fmt.Errorf("write DNS proxy configuration: %w", err)
	}
	return nil
}

func verifyHostDNS(coreDNSIP string, zones []string) error {
	if len(zones) == 0 {
		return fmt.Errorf("no CoreDNS zones available for verification")
	}
	queryName := "kubernetes.default.svc." + zones[0]
	if _, err := net.LookupHost(queryName); err != nil {
		return fmt.Errorf("verify host DNS query for %s through CoreDNS service %s: %w", queryName, coreDNSIP, err)
	}
	return nil
}

func configureAptProxy(proxyURL string, configDir string) error {
	content := []byte(fmt.Sprintf("%s\nAcquire::http::Proxy \"%s\";\nAcquire::https::Proxy \"%s\";\n", aptProxyConfigHeader, proxyURL, proxyURL))
	current, err := os.ReadFile(aptProxyConfig)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("read existing apt proxy configuration: %w", err)
	}

	backupPath := filepath.Join(configDir, "apt-proxy.conf.pre-k2s")
	if len(current) > 0 && !strings.Contains(string(current), aptProxyConfigHeader) {
		if _, err := os.Stat(backupPath); err == nil {
			return fmt.Errorf("refusing to overwrite apt proxy configuration because backup %s already exists", backupPath)
		} else if !os.IsNotExist(err) {
			return fmt.Errorf("inspect apt proxy backup: %w", err)
		}
		if err := os.MkdirAll(configDir, 0700); err != nil {
			return fmt.Errorf("create apt proxy backup directory: %w", err)
		}
		if err := os.WriteFile(backupPath, current, 0600); err != nil {
			return fmt.Errorf("back up existing apt proxy configuration: %w", err)
		}
	}

	if err := os.WriteFile(aptProxyConfig, content, 0644); err != nil {
		return fmt.Errorf("write K2s apt proxy configuration: %w", err)
	}
	slog.Info("[Install] Configured apt to use the KubeSwitch HTTP proxy", "proxy", proxyURL)
	return nil
}

func removeAptProxy(configDir string) {
	content, err := os.ReadFile(aptProxyConfig)
	if err != nil {
		if !os.IsNotExist(err) {
			slog.Warn("[Uninstall] Could not read apt proxy configuration", "path", aptProxyConfig, "error", err)
		}
		return
	}
	if !strings.Contains(string(content), aptProxyConfigHeader) {
		slog.Warn("[Uninstall] Leaving apt proxy configuration unchanged because it is not managed by K2s", "path", aptProxyConfig)
		return
	}

	backupPath := filepath.Join(configDir, "apt-proxy.conf.pre-k2s")
	backup, backupErr := os.ReadFile(backupPath)
	if backupErr == nil {
		if err := os.WriteFile(aptProxyConfig, backup, 0644); err != nil {
			slog.Warn("[Uninstall] Could not restore pre-existing apt proxy configuration", "path", aptProxyConfig, "error", err)
			return
		}
		if err := os.Remove(backupPath); err != nil && !os.IsNotExist(err) {
			slog.Warn("[Uninstall] Could not remove apt proxy backup", "path", backupPath, "error", err)
		}
		return
	}
	if !os.IsNotExist(backupErr) {
		slog.Warn("[Uninstall] Could not read apt proxy backup", "path", backupPath, "error", backupErr)
		return
	}
	if err := os.Remove(aptProxyConfig); err != nil && !os.IsNotExist(err) {
		slog.Warn("[Uninstall] Could not remove K2s apt proxy configuration", "path", aptProxyConfig, "error", err)
	}
}

func removeCriOProxyConfiguration() {
	if err := os.Remove(criOProxyConfig); err != nil && !os.IsNotExist(err) {
		slog.Warn("[Uninstall] Could not remove K2s CRI-O proxy configuration", "path", criOProxyConfig, "error", err)
		return
	}
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		slog.Warn("[Uninstall] Could not reload systemd after CRI-O proxy cleanup", "error", err)
		return
	}
	if err := runCommand("systemctl", "is-active", "--quiet", crioServiceName); err == nil {
		if err := runCommand("systemctl", "restart", crioServiceName); err != nil {
			slog.Warn("[Uninstall] Could not restart CRI-O after proxy cleanup", "error", err)
		}
	}
}

func removeContainersProxyConfiguration() {
	if err := os.Remove(containersProxyConfig); err != nil && !os.IsNotExist(err) {
		slog.Warn("[Uninstall] Could not remove K2s containers proxy configuration", "path", containersProxyConfig, "error", err)
	}
}

func configureKubeletFileLogging() error {
	if err := ensureServiceLogFile(kubeletLogDir, kubeletLogFile); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(kubeletLogDropIn), 0755); err != nil {
		return fmt.Errorf("create kubelet logging drop-in directory: %w", err)
	}
	dropIn := fmt.Sprintf(`[Service]
StandardOutput=append:%s
StandardError=append:%s
`, kubeletLogFile, kubeletLogFile)
	if err := os.WriteFile(kubeletLogDropIn, []byte(dropIn), 0644); err != nil {
		return fmt.Errorf("write kubelet logging drop-in: %w", err)
	}
	if err := runCommand("systemctl", "daemon-reload"); err != nil {
		return fmt.Errorf("reload systemd after kubelet logging setup: %w", err)
	}
	return nil
}

func removeKubeletFileLogging() {
	if err := os.Remove(kubeletLogDropIn); err != nil && !os.IsNotExist(err) {
		slog.Warn("[Uninstall] Could not remove K2s kubelet logging drop-in", "path", kubeletLogDropIn, "error", err)
	}
	_ = runCommand("systemctl", "daemon-reload")
}

func ensureServiceLogFile(logDir string, logFile string) error {
	if err := os.MkdirAll(logDir, 0755); err != nil {
		return fmt.Errorf("create log directory %s: %w", logDir, err)
	}
	file, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("open log file %s: %w", logFile, err)
	}
	return file.Close()
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
`, proxyNetworkDev, proxyNetworkDev, proxyNetwork.AddressCIDR, proxyNetworkDev, proxyNetworkDev, proxyNetworkDev)
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
	if !strings.Contains(output, proxyNetwork.AddressCIDR) {
		return false, fmt.Errorf("existing interface %q does not own required configured KubeSwitch address %s; remove or correct it before installing K2s", proxyNetworkDev, proxyNetwork.AddressCIDR)
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

// primaryHostIPv4 returns the IPv4 source address selected by the host's
// default route. The local proxy needs this exact /32 allow-list entry so
// host processes can reach the KubeSwitch endpoint without exposing it to
// other hosts on the primary network.
func primaryHostIPv4() (string, error) {
	route, err := runCommandOutput("ip", "-4", "route", "get", "1.1.1.1")
	if err != nil {
		return "", fmt.Errorf("inspect IPv4 default route: %w", err)
	}
	return primaryHostIPv4FromRoute(route)
}

func primaryHostIPv4FromRoute(route string) (string, error) {
	fields := strings.Fields(route)
	for index, field := range fields {
		if field != "src" || index+1 >= len(fields) {
			continue
		}

		address := net.ParseIP(fields[index+1])
		if address == nil || address.To4() == nil || address.IsLoopback() || address.IsUnspecified() || address.IsLinkLocalUnicast() {
			return "", fmt.Errorf("default route returned invalid primary IPv4 address %q", fields[index+1])
		}
		return address.String(), nil
	}
	return "", fmt.Errorf("could not find source address in IPv4 route %q", strings.TrimSpace(route))
}

// kubeSwitchProxyURL returns the stable K2s proxy endpoint used by Linux
// control-plane VMs on Windows hosts and by the native Linux host. The native
// proxy is deliberately accessed through this address rather than loopback so
// APT and CRI-O use the same configuration in both topologies.
func kubeSwitchProxyURL(installDir string) (string, error) {
	proxyNetwork, err := config.ReadKubeSwitchConfig(installDir)
	if err != nil {
		return "", fmt.Errorf("read KubeSwitch proxy configuration: %w", err)
	}
	return "http://" + proxyNetwork.Address + ":8181", nil
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
	value, err := normalizeRegistryToken(string(data))
	if err != nil {
		return "", fmt.Errorf("invalid packaged registry credentials at %s: %w", path, err)
	}
	return value, nil
}

func normalizeRegistryToken(value string) (string, error) {
	value = strings.TrimPrefix(strings.TrimSpace(value), "\uFEFF")
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("credential is empty")
	}
	if _, err := base64.StdEncoding.DecodeString(value); err != nil {
		return "", fmt.Errorf("credential is not valid base64")
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
