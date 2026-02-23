// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"bytes"
	"fmt"
	"log/slog"
	"os"
	"strings"

	"embed"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

type Kind string

type installConfigAccess struct {
	config             *viper.Viper
	embeddedFileReader fileReader
	osFileReader       fileReader
	validator          configValidator
	converter          configConverter
	overwriter         configOverwriter
}

type embeddedFileReader struct{}

type osFileReader struct{}

type userConfigValidator struct{}

type viperConfigConverter struct{}

type cliParamsConfigOverwriter struct{}

type fileReader interface {
	readFile(path string) ([]byte, error)
}

type configValidator interface {
	validate(kind Kind, config *viper.Viper) error
}

type configConverter interface {
	convert(config *viper.Viper) (*InstallConfig, error)
}

type configOverwriter interface {
	overwrite(iConfig *InstallConfig, vConfig *viper.Viper, flags *pflag.FlagSet)
}

type InstallConfig struct {
	Kind       string         `mapstructure:"kind"`
	ApiVersion string         `mapstructure:"apiVersion"`
	Nodes      []NodeConfig   `mapstructure:"nodes"`
	Env        EnvConfig      `mapstructure:"env"`
	Behavior   BehaviorConfig `mapstructure:"installBehavior"`
	LinuxOnly  bool           `mapstructure:"linuxOnly"`
}

type NodeConfig struct {
	Role      string         `mapstructure:"role"`
	Resources ResourceConfig `mapstructure:"resources"`
}

type ResourceConfig struct {
	Cpu          string `mapstructure:"cpu"`
	Memory       string `mapstructure:"memory"`
	MemoryMin    string `mapstructure:"memoryMin"`
	MemoryMax    string `mapstructure:"memoryMax"`
	DynamicMemory bool  `mapstructure:"dynamicMemory"`
	Disk         string `mapstructure:"disk"`
}

type EnvConfig struct {
	Proxy              string   `mapstructure:"httpProxy"`
	NoProxy            []string `mapstructure:"noProxy"`
	AdditionalHooksDir string   `mapstructure:"additionalHooksDir"`
	RestartPostInstall string   `mapstructure:"restartPostInstallCount"`
	K8sBins            string   `mapstructure:"k8sBins"`
}

type BehaviorConfig struct {
	ShowOutput                        bool `mapstructure:"showOutput"`
	DeleteFilesForOfflineInstallation bool `mapstructure:"deleteFilesForOfflineInstallation"`
	ForceOnlineInstallation           bool `mapstructure:"forceOnlineInstallation"`
	Wsl                               bool `mapstructure:"wsl"`
	AppendLog                         bool `mapstructure:"appendLog"`
	SkipStart                         bool `mapstructure:"skipStart"`
}

const (
	k2sConfigType       Kind = "k2s"
	BuildonlyConfigType Kind = "buildonly"

	SupportedApiVersion  = "v1"
	ControlPlaneRoleName = "control-plane"

	ControlPlaneCPUsFlagName  = "master-cpus"
	ControlPlaneCPUsFlagUsage = "Number of CPUs allocated to master VM"

	ControlPlaneMemoryFlagName  = "master-memory"
	ControlPlaneMemoryFlagUsage = "Amount of RAM to allocate to master VM (minimum 2GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneMemoryMinFlagName  = "master-memory-min"
	ControlPlaneMemoryMinFlagUsage = "Minimum amount of RAM for dynamic memory (format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneMemoryMaxFlagName  = "master-memory-max"
	ControlPlaneMemoryMaxFlagUsage = "Maximum amount of RAM for dynamic memory (format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneDynamicMemoryFlagName  = "master-dynamic-memory"
	ControlPlaneDynamicMemoryFlagUsage = "Enable Hyper-V dynamic memory management for master VM"

	ControlPlaneDiskSizeFlagName  = "master-disk"
	ControlPlaneDiskSizeFlagUsage = "Disk size allocated to the master VM (minimum 10GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ProxyFlagName      = "proxy"
	ProxyFlagShorthand = "p"
	ProxyFlagUsage     = "HTTP Proxy"

	NoProxyFlagName  = "no-proxy"
	NoProxyFlagUsage = "No proxy hosts/domains (comma-separated list)"

	ConfigFileFlagName      = "config"
	ConfigFileFlagShorthand = "c"
	ConfigFileFlagUsage     = "Path to config file to load. This configuration overwrites other CLI parameters"

	WslFlagName  = "wsl"
	WslFlagUsage = "Use WSL2 for hosting of KubeMaster"

	K8sBinFlagName  = "k8s-bins"
	K8sBinFlagUsage = "Path to directory of locally built Kubernetes binaries (kubelet.exe, kube-proxy.exe, kubeadm.exe, kubectl.exe)"

	LinuxOnlyFlagName  = "linux-only"
	LinuxOnlyFlagUsage = "No Windows worker node will be set up"

	AppendLogFlagName  = "append-log"
	AppendLogFlagUsage = "Append logs to existing log file"

	SkipStartFlagName  = "skip-start"
	SkipStartFlagUsage = "Do not start the K8s cluster automatically after installation"

	RestartFlagUsage = "Number of times to restart cluster post installation."
)

var (
	//go:embed embed/*.config.yaml
	embeddedConfigFiles embed.FS

	configFileMap map[Kind]string = map[Kind]string{
		k2sConfigType:       "k2s.config.yaml",
		BuildonlyConfigType: "buildonly.config.yaml"}
)

func NewInstallConfigAccess() *installConfigAccess {
	return &installConfigAccess{
		config:             viper.New(),
		embeddedFileReader: &embeddedFileReader{},
		osFileReader:       &osFileReader{},
		validator:          &userConfigValidator{},
		converter:          &viperConfigConverter{},
		overwriter:         &cliParamsConfigOverwriter{},
	}
}

func (i *installConfigAccess) Load(kind Kind, flags *pflag.FlagSet) (*InstallConfig, error) {
	i.config.BindPFlags(flags)

	err := i.loadBaseConfig(kind)
	if err != nil {
		return nil, err
	}

	if i.config.IsSet(ConfigFileFlagName) {
		err = i.loadUserConfig(kind)
		if err != nil {
			return nil, err
		}
	}

	config, err := i.converter.convert(i.config)
	if err != nil {
		return nil, err
	}

	i.overwriter.overwrite(config, i.config, flags)

	// Validate the final configuration after all overrides
	err = validateDynamicMemoryConfiguration(config)
	if err != nil {
		return nil, err
	}

	// Validate WSL compatibility
	err = validateWslCompatibility(config)
	if err != nil {
		return nil, err
	}

	return config, nil
}

func (config *InstallConfig) GetNodeByRole(role string) (*NodeConfig, error) {
	result, found := config.findNodeByRole(role)

	if !found {
		return nil, fmt.Errorf("node config not found for role '%s'", role)
	}

	return result, nil
}

func (i *installConfigAccess) loadBaseConfig(kind Kind) error {
	configPath := fmt.Sprintf("embed/%s", configFileMap[kind])

	slog.Debug("Loading embedded config file", "path", configPath)

	content, err := i.embeddedFileReader.readFile(configPath)
	if err != nil {
		return err
	}

	i.config.SetConfigType("yaml")

	slog.Debug("Parsing embedded config file")

	return i.config.ReadConfig(bytes.NewReader(content))
}

func (i *installConfigAccess) loadUserConfig(kind Kind) error {
	userPath := i.config.GetString(ConfigFileFlagName)

	slog.Debug("Loading user-provided config file", "path", userPath)

	userContent, err := i.osFileReader.readFile(userPath)
	if err != nil {
		return err
	}

	slog.Debug("Parsing and merging user-provided config file")

	err = i.config.ReadConfig(bytes.NewReader(userContent))
	if err != nil {
		return err
	}

	return i.validator.validate(kind, i.config)
}

func (config *InstallConfig) findNodeByRole(role string) (*NodeConfig, bool) {
	for i := range config.Nodes {
		if config.Nodes[i].Role == role {
			return &config.Nodes[i], true
		}
	}
	return nil, false
}

func (config *InstallConfig) getNodeByRolePanic(role string) *NodeConfig {
	result, found := config.findNodeByRole(role)

	if !found {
		panic(fmt.Errorf("node config not found for role '%s'", role))
	}

	return result
}

func (*userConfigValidator) validate(kind Kind, config *viper.Viper) error {
	slog.Debug("Validating user-provided config file")

	if Kind(config.GetString("kind")) != kind {
		return fmt.Errorf("error in user-provided config: expected kind '%s', but found: '%s'", kind, config.GetString("kind"))
	}

	if config.GetString("apiVersion") != SupportedApiVersion {
		return fmt.Errorf("error in user-provided config: API version mismatch. Supported: %s, found: '%s'", SupportedApiVersion, config.GetString("apiVersion"))
	}

	nodes := config.Get("nodes").([]any)
	for _, node := range nodes {
		n := node.(map[string]any)

		if n["role"] != ControlPlaneRoleName {
			return fmt.Errorf("error in user-provided config: Invalid node role name. Supported: (%s), found: '%s'", ControlPlaneRoleName, n["role"])
		}
	}

	return nil
}

func (*viperConfigConverter) convert(config *viper.Viper) (*InstallConfig, error) {
	var result InstallConfig

	err := config.Unmarshal(&result)
	if err != nil {
		return nil, err
	}

	return &result, nil
}

func (*cliParamsConfigOverwriter) overwrite(iConfig *InstallConfig, vConfig *viper.Viper, flags *pflag.FlagSet) {
	slog.Debug("Overwriting config with CLI params")

	flags.Visit(func(flag *pflag.Flag) {
		overwriteConfigWithCliParam(iConfig, vConfig, flag.Name)
	})
}

func overwriteConfigWithCliParam(iConfig *InstallConfig, vConfig *viper.Viper, flagName string) {
	slog.Debug("Overwriting config with CLI param", "param", flagName)

	switch flagName {
	case common.AdditionalHooksDirFlagName:
		iConfig.Env.AdditionalHooksDir = vConfig.GetString(flagName)
	case common.ForceOnlineInstallFlagName:
		iConfig.Behavior.ForceOnlineInstallation = vConfig.GetBool(flagName)
	case common.DeleteFilesFlagName:
		iConfig.Behavior.DeleteFilesForOfflineInstallation = vConfig.GetBool(flagName)
	case common.OutputFlagName:
		iConfig.Behavior.ShowOutput = vConfig.GetBool(flagName)
	case AppendLogFlagName:
		iConfig.Behavior.AppendLog = vConfig.GetBool(flagName)
	case LinuxOnlyFlagName:
		iConfig.LinuxOnly = vConfig.GetBool(flagName)
	case ControlPlaneCPUsFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Cpu = vConfig.GetString(flagName)
	case ControlPlaneDiskSizeFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Disk = vConfig.GetString(flagName)
	case ControlPlaneMemoryFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.Memory = vConfig.GetString(flagName)
	case ControlPlaneMemoryMinFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.MemoryMin = vConfig.GetString(flagName)
	case ControlPlaneMemoryMaxFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.MemoryMax = vConfig.GetString(flagName)
	case ControlPlaneDynamicMemoryFlagName:
		(iConfig.getNodeByRolePanic(ControlPlaneRoleName)).Resources.DynamicMemory = vConfig.GetBool(flagName)
	case ProxyFlagName:
		iConfig.Env.Proxy = vConfig.GetString(flagName)
	case NoProxyFlagName:
		iConfig.Env.NoProxy = vConfig.GetStringSlice(flagName)
	case SkipStartFlagName:
		iConfig.Behavior.SkipStart = vConfig.GetBool(flagName)
	case WslFlagName:
		iConfig.Behavior.Wsl = vConfig.GetBool(flagName)
	case K8sBinFlagName:
		iConfig.Env.K8sBins = vConfig.GetString(flagName)
	}
}

func (*embeddedFileReader) readFile(path string) ([]byte, error) {
	return embeddedConfigFiles.ReadFile(path)
}

func (*osFileReader) readFile(path string) ([]byte, error) {
	return os.ReadFile(path)
}

// validateDynamicMemoryConfiguration validates dynamic memory settings
func validateDynamicMemoryConfiguration(config *InstallConfig) error {
	for i := range config.Nodes {
		node := &config.Nodes[i]

		// Only validate if dynamic memory is enabled
		if !node.Resources.DynamicMemory {
			continue
		}

		// Parse memory sizes if specified
		var minBytes, maxBytes, startupBytes int64
		var err error

		if node.Resources.MemoryMin != "" {
			minBytes, err = parseMemorySize(node.Resources.MemoryMin)
			if err != nil {
				return fmt.Errorf("invalid memory minimum value '%s': %w", node.Resources.MemoryMin, err)
			}
			slog.Debug("Parsed MemoryMin", "input", node.Resources.MemoryMin, "bytes", minBytes, "GB", float64(minBytes)/(1000*1000*1000))
		}

		if node.Resources.MemoryMax != "" {
			maxBytes, err = parseMemorySize(node.Resources.MemoryMax)
			if err != nil {
				return fmt.Errorf("invalid memory maximum value '%s': %w", node.Resources.MemoryMax, err)
			}
			slog.Debug("Parsed MemoryMax", "input", node.Resources.MemoryMax, "bytes", maxBytes, "GB", float64(maxBytes)/(1000*1000*1000))
		}

		if node.Resources.Memory != "" {
			startupBytes, err = parseMemorySize(node.Resources.Memory)
			if err != nil {
				return fmt.Errorf("invalid memory value '%s': %w", node.Resources.Memory, err)
			}
			slog.Debug("Parsed Memory", "input", node.Resources.Memory, "bytes", startupBytes, "GB", float64(startupBytes)/(1000*1000*1000))
		}

		// Debug logging
		slog.Debug("Validation checks",
			"minBytes > maxBytes", minBytes > maxBytes,
			"minBytes > startupBytes", minBytes > startupBytes,
			"maxBytes < startupBytes", maxBytes < startupBytes)

		// Validate min <= max (only if both are specified)
		if node.Resources.MemoryMin != "" && node.Resources.MemoryMax != "" {
			if minBytes > maxBytes {
				return fmt.Errorf("dynamic memory configuration error: minimum memory (%s) cannot be greater than maximum memory (%s)",
					node.Resources.MemoryMin, node.Resources.MemoryMax)
			}
		}

		// Validate min <= startup (only if both are specified)
		if node.Resources.MemoryMin != "" && node.Resources.Memory != "" {
			if minBytes > startupBytes {
				return fmt.Errorf("dynamic memory configuration error: minimum memory (%s) cannot be greater than startup memory (%s)",
					node.Resources.MemoryMin, node.Resources.Memory)
			}
		}

		// Validate max >= startup (only if both are specified)
		if node.Resources.MemoryMax != "" && node.Resources.Memory != "" {
			if maxBytes < startupBytes {
				return fmt.Errorf("dynamic memory configuration error: maximum memory (%s) cannot be less than startup memory (%s)",
					node.Resources.MemoryMax, node.Resources.Memory)
			}
		}
	}

	return nil
}

// validateWslCompatibility validates WSL-specific configurations
func validateWslCompatibility(config *InstallConfig) error {
	// WSL + Dynamic Memory is not supported
	if config.Behavior.Wsl {
		for i := range config.Nodes {
			node := &config.Nodes[i]
			if node.Resources.DynamicMemory {
				return fmt.Errorf("dynamic memory configuration error: dynamic memory (--master-dynamic-memory) is not supported with WSL2 (--wsl). WSL2 has its own memory management. Please remove either --master-dynamic-memory or --wsl flag")
			}
		}
	}

	return nil
}

// parseMemorySize parses memory size strings like "4GB", "8GB", etc.
func parseMemorySize(size string) (int64, error) {
	if size == "" {
		return 0, fmt.Errorf("empty memory size")
	}

	size = strings.TrimSpace(size)
	size = strings.ToUpper(size)

	// Define suffixes in order from longest to shortest to avoid partial matches
	// For example, "GB" should be checked before "B" to avoid "4GB" matching as "4 G B" → "4 * B"
	suffixes := []struct {
		suffix     string
		multiplier int64
	}{
		{"TB", 1000 * 1000 * 1000 * 1000},
		{"GB", 1000 * 1000 * 1000},
		{"MB", 1000 * 1000},
		{"KB", 1000},
		{"T", 1024 * 1024 * 1024 * 1024},
		{"G", 1024 * 1024 * 1024},
		{"M", 1024 * 1024},
		{"K", 1024},
		{"B", 1},
	}

	// Try each suffix in order (longest first)
	for _, s := range suffixes {
		if strings.HasSuffix(size, s.suffix) {
			numStr := strings.TrimSuffix(size, s.suffix)
			numStr = strings.TrimSpace(numStr)

			var num float64
			_, err := fmt.Sscanf(numStr, "%f", &num)
			if err != nil {
				continue
			}

			return int64(num * float64(s.multiplier)), nil
		}
	}

	// Try parsing as plain number (bytes)
	var num int64
	_, err := fmt.Sscanf(size, "%d", &num)
	if err != nil {
		return 0, fmt.Errorf("unable to parse memory size: %s", size)
	}

	return num, nil
}

