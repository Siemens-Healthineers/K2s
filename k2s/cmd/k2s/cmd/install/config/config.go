// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"bytes"
	"fmt"
	"log/slog"
	"os"

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
	Cpu    string `mapstructure:"cpu"`
	Memory string `mapstructure:"memory"`
	Disk   string `mapstructure:"disk"`
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
