// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config

import (
	"errors"
	"fmt"
	"os"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	r "github.com/siemens-healthineers/k2s/internal/reflection"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/pflag"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

const (
	testConfigFilePath = "config_test.yaml"
)

func (m *mockObject) readFile(path string) ([]byte, error) {
	args := m.Called(path)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *mockObject) convert(config *viper.Viper) (*InstallConfig, error) {
	args := m.Called(config)

	return args.Get(0).(*InstallConfig), args.Error(1)
}

func (m *mockObject) overwrite(iConfig *InstallConfig, vConfig *viper.Viper, flags *pflag.FlagSet) {
	m.Called(iConfig, vConfig, flags)
}

func (m *mockObject) validate(kind Kind, config *viper.Viper) error {
	args := m.Called(kind, config)

	return args.Error(0)
}

func TestConfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "config Unit Tests", Label("unit", "ci"))
}

var _ = Describe("config", func() {
	Describe("NewInstallConfigAccess", func() {
		It("returns initialized deps", func() {
			result := NewInstallConfigAccess()

			Expect(result).ToNot(BeNil())
			Expect(result.config).ToNot(BeNil())
			Expect(result.embeddedFileReader).ToNot(BeNil())
			Expect(result.osFileReader).ToNot(BeNil())
			Expect(result.validator).ToNot(BeNil())
			Expect(result.converter).ToNot(BeNil())
			Expect(result.overwriter).ToNot(BeNil())
		})
	})

	Describe("Load", func() {
		When("base config load failed", func() {
			It("returns an error", func() {
				kind := Kind("test-kind")
				flags := &pflag.FlagSet{}
				expectedError := errors.New("oops")
				configFileName := "test-file"
				configFilePath := "embed/test-file"
				configFileMap = map[Kind]string{kind: configFileName}

				readerMock := &mockObject{}
				readerMock.On(r.GetFunctionName(readerMock.readFile), configFilePath).Return([]byte{}, expectedError)

				sut := installConfigAccess{
					embeddedFileReader: readerMock,
				}

				actual, err := sut.Load(kind, flags)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedError))
			})
		})

		When("user config load failed", func() {
			It("returns an error", func() {
				expectedError := errors.New("oops")
				configFileName := "test-file"
				configFilePath := fmt.Sprintf("embed/%s", configFileName)
				userConfigFileName := "user-test-file"
				kind := Kind("test-kind")

				flags := &pflag.FlagSet{}
				vConfig := viper.New()
				vConfig.Set(ConfigFileFlagName, userConfigFileName)

				configFileMap = map[Kind]string{kind: configFileName}

				embeddedReaderMock := &mockObject{}
				embeddedReaderMock.On(r.GetFunctionName(embeddedReaderMock.readFile), configFilePath).Return(readTestConfig())

				osReaderMock := &mockObject{}
				osReaderMock.On(r.GetFunctionName(osReaderMock.readFile), userConfigFileName).Return([]byte{}, expectedError)

				sut := installConfigAccess{
					embeddedFileReader: embeddedReaderMock,
					osFileReader:       osReaderMock,
					config:             vConfig,
				}

				actual, err := sut.Load(kind, flags)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedError))
			})
		})

		When("conversion failed", func() {
			It("returns an error", func() {
				var nilValue *InstallConfig
				expectedError := errors.New("oops")
				configFileName := "test-file"
				configFilePath := fmt.Sprintf("embed/%s", configFileName)
				kind := Kind("test-kind")

				flags := &pflag.FlagSet{}
				vConfig := viper.New()

				configFileMap = map[Kind]string{kind: configFileName}

				embeddedReaderMock := &mockObject{}
				embeddedReaderMock.On(r.GetFunctionName(embeddedReaderMock.readFile), configFilePath).Return(readTestConfig())

				converterMock := &mockObject{}
				converterMock.On(r.GetFunctionName(converterMock.convert), vConfig).Return(nilValue, expectedError)

				sut := installConfigAccess{
					embeddedFileReader: embeddedReaderMock,
					config:             vConfig,
					converter:          converterMock,
				}

				actual, err := sut.Load(kind, flags)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedError))
			})
		})

		When("all succeeds", func() {
			It("returns config", func() {
				configFileName := "test-file"
				configFilePath := fmt.Sprintf("embed/%s", configFileName)

				kind := Kind("test-kind")
				flags := &pflag.FlagSet{}
				vConfig := viper.New()
				iConfig := &InstallConfig{}

				configFileMap = map[Kind]string{kind: configFileName}

				embeddedReaderMock := &mockObject{}
				embeddedReaderMock.On(r.GetFunctionName(embeddedReaderMock.readFile), configFilePath).Return(readTestConfig())

				converterMock := &mockObject{}
				converterMock.On(r.GetFunctionName(converterMock.convert), vConfig).Return(iConfig, nil)

				overwriterMock := &mockObject{}
				overwriterMock.On(r.GetFunctionName(overwriterMock.overwrite), iConfig, vConfig, flags)

				sut := installConfigAccess{
					embeddedFileReader: embeddedReaderMock,
					config:             vConfig,
					converter:          converterMock,
					overwriter:         overwriterMock,
				}

				actual, err := sut.Load(kind, flags)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(iConfig))
			})
		})
	})

	Describe("GetNodeByRole", func() {
		When("node not found", func() {
			It("returns an error", func() {
				role := "test-role"
				sut := &InstallConfig{}

				actual, err := sut.GetNodeByRole(role)

				Expect(actual).To(BeNil())
				Expect(err).To(SatisfyAll(
					MatchError(ContainSubstring(role)),
					MatchError(ContainSubstring("not found")),
				))
			})
		})

		When("matching node found", func() {
			It("returns the node", func() {
				role := "test-role"
				sut := &InstallConfig{Nodes: []NodeConfig{{Role: role}}}

				actual, err := sut.GetNodeByRole(role)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).ToNot(BeNil())
				Expect(*actual).To(Equal(sut.Nodes[0]))
			})
		})
	})

	Describe("loadBaseConfig", func() {
		When("config reading error occurred", func() {
			It("returns an error", func() {
				configFileName := "test-file"
				configFilePath := fmt.Sprintf("embed/%s", configFileName)
				kind := Kind("test-kind")

				configFileMap = map[Kind]string{kind: configFileName}

				embeddedReaderMock := &mockObject{}
				embeddedReaderMock.On(r.GetFunctionName(embeddedReaderMock.readFile), configFilePath).Return([]byte("invalid yaml"), nil)

				sut := &installConfigAccess{
					embeddedFileReader: embeddedReaderMock,
					config:             viper.New()}

				err := sut.loadBaseConfig(kind)

				Expect(err).To(MatchError(ContainSubstring("unmarshal errors")))
			})
		})
	})

	Describe("loadUserConfig", func() {
		When("config reading error occurred", func() {
			It("returns an error", func() {
				configFilePath := "path-to-user-test-config"
				config := viper.New()
				config.Set(ConfigFileFlagName, configFilePath)
				config.SetConfigType("yaml")

				osReaderMock := &mockObject{}
				osReaderMock.On(r.GetFunctionName(osReaderMock.readFile), configFilePath).Return([]byte("invalid yaml"), nil)

				sut := &installConfigAccess{
					osFileReader: osReaderMock,
					config:       config}

				err := sut.loadUserConfig("")

				Expect(err).To(MatchError(ContainSubstring("unmarshal errors")))
			})
		})

		When("validation error occurred", func() {
			It("returns an error", func() {
				kind := Kind("test-kind")
				expectedError := errors.New("cannot decode configuration: unable to determine config type")
				configFilePath := "path-to-user-test-config"
				config := viper.New()
				config.Set(ConfigFileFlagName, configFilePath)

				osReaderMock := &mockObject{}
				osReaderMock.On(r.GetFunctionName(osReaderMock.readFile), configFilePath).Return([]byte("some data"), nil)

				validatorMock := &mockObject{}
				validatorMock.On(r.GetFunctionName(validatorMock.validate), kind, config).Return(expectedError)

				sut := &installConfigAccess{
					osFileReader: osReaderMock,
					config:       config,
					validator:    validatorMock}

				err := sut.loadUserConfig(kind)

				Expect(err).To(MatchError(expectedError))
			})
		})

		When("successful", func() {
			It("returns nil", func() {
				kind := Kind("test-kind")
				configFilePath := "path-to-user-test-config" 
				config := viper.New()
				config.Set(ConfigFileFlagName, configFilePath)
				
				config.SetConfigType("yaml") 

				osReaderMock := &mockObject{}
				// --- CHANGE THIS LINE ---
				// Provide valid YAML data for the mock to return
				osReaderMock.On(r.GetFunctionName(osReaderMock.readFile), configFilePath).Return([]byte("some: data"), nil)

				validatorMock := &mockObject{}
				validatorMock.On(r.GetFunctionName(validatorMock.validate), kind, config).Return(nil)

				sut := &installConfigAccess{
					osFileReader: osReaderMock,
					config:       config,
					validator:    validatorMock}

				Expect(sut.loadUserConfig(kind)).To(Succeed())
			})
		})

	})

	Describe("findNodeByRole", func() {
		When("no match", func() {
			It("returns nil and false", func() {
				role := "test-role"
				sut := &InstallConfig{}

				node, found := sut.findNodeByRole(role)

				Expect(node).To(BeNil())
				Expect(found).To(BeFalse())
			})
		})

		When("match", func() {
			It("returns node and true", func() {
				role := "test-role"
				sut := &InstallConfig{Nodes: []NodeConfig{{Role: role}}}

				node, found := sut.findNodeByRole(role)

				Expect(*node).To(Equal(sut.Nodes[0]))
				Expect(found).To(BeTrue())
			})
		})
	})

	Describe("getNodeByRolePanic", func() {
		When("node not found", func() {
			It("panics", func() {
				defer func() {
					if r := recover(); r == nil {
						Fail("panic expected")
					}
				}()

				sut := &InstallConfig{}

				sut.getNodeByRolePanic("panic!")
			})
		})

		When("node found", func() {
			It("returns the node", func() {
				role := "test-role"
				sut := &InstallConfig{Nodes: []NodeConfig{{Role: role}}}

				node := sut.getNodeByRolePanic(role)
				Expect(*node).To(Equal(sut.Nodes[0]))
			})
		})
	})

	Describe("validate", func() {
		When("kind is invalid", func() {
			It("returns an error", func() {
				config := viper.New()
				config.Set("kind", "invalid-kind")

				sut := &userConfigValidator{}

				err := sut.validate("test-kind", config)

				Expect(err).To(MatchError(ContainSubstring("expected kind 'test-kind', but found: 'invalid-kind'")))
			})
		})

		When("API version is invalid", func() {
			It("returns an error", func() {
				kind := "test-kind"

				config := viper.New()
				config.Set("kind", kind)
				config.Set("apiVersion", "invalid-api-version")

				sut := &userConfigValidator{}

				err := sut.validate(Kind(kind), config)

				Expect(err).To(SatisfyAll(
					MatchError(ContainSubstring("API version mismatch")),
					MatchError(ContainSubstring("found: 'invalid-api-version'")),
				))
			})
		})

		When("nodes have invalid roles", func() {
			It("returns an error", func() {
				kind := "test-kind"
				nodes := []any{map[string]any{"role": "invalid-role"}}

				config := viper.New()
				config.Set("kind", kind)
				config.Set("apiVersion", SupportedApiVersion)
				config.Set("nodes", nodes)

				sut := &userConfigValidator{}

				err := sut.validate(Kind(kind), config)

				Expect(err).To(SatisfyAll(
					MatchError(ContainSubstring("Invalid node role name")),
					MatchError(ContainSubstring("found: 'invalid-role'")),
				))
			})
		})

		When("nodes have control-plane role", func() {
			It("returns nil", func() {
				kind := "test-kind"
				nodes := []any{map[string]any{"role": ControlPlaneRoleName}}

				config := viper.New()
				config.Set("kind", kind)
				config.Set("apiVersion", SupportedApiVersion)
				config.Set("nodes", nodes)

				sut := &userConfigValidator{}

				Expect(sut.validate(Kind(kind), config)).To(Succeed())
			})
		})

		When("no nodes exist", func() {
			It("returns nil", func() {
				kind := "test-kind"

				config := viper.New()
				config.Set("kind", kind)
				config.Set("apiVersion", SupportedApiVersion)
				config.Set("nodes", []any{})

				sut := &userConfigValidator{}

				Expect(sut.validate(Kind(kind), config)).To(Succeed())
			})
		})
	})

	Describe("convert", func() {
		When("error occurred", func() {
			It("returns the error", func() {
				invalidValue := InstallConfig{}

				config := viper.New()
				config.Set("kind", invalidValue)

				sut := &viperConfigConverter{}

				actual, err := sut.convert(config)

				Expect(actual).To(BeNil())
				Expect(err).To(HaveOccurred())
			})
		})

		When("successful", func() {
			It("returns unmarshal result", func() {
				kind := "test-kind"
				apiVersion := "test-api-version"

				config := viper.New()
				config.Set("kind", kind)
				config.Set("apiVersion", apiVersion)

				sut := &viperConfigConverter{}

				actual, err := sut.convert(config)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).ToNot(BeNil())
				Expect(actual.Kind).To(Equal(kind))
				Expect(actual.ApiVersion).To(Equal(apiVersion))
			})
		})
	})

	Describe("overwrite", func() {
		When("certain flags are set", func() {
			It("sets properties only for that flags", func() {
				iConfig := &InstallConfig{Nodes: []NodeConfig{
					{
						Resources: ResourceConfig{Disk: "initial-size", Memory: "initial-mem"},
						Role:      ControlPlaneRoleName,
					},
				}}
				vConfig := viper.New()

				flags := &pflag.FlagSet{}
				flags.String(ControlPlaneDiskSizeFlagName, "", ControlPlaneDiskSizeFlagUsage)
				flags.String(ControlPlaneMemoryFlagName, "", ControlPlaneMemoryFlagUsage)

				flags.Set(ControlPlaneMemoryFlagName, "modified-mem")

				vConfig.BindPFlags(flags)

				sut := &cliParamsConfigOverwriter{}

				sut.overwrite(iConfig, vConfig, flags)

				Expect(iConfig.Nodes[0].Resources.Memory).To(Equal("modified-mem"))
				Expect(iConfig.Nodes[0].Resources.Disk).To(Equal("initial-size"))
			})
		})
	})

	Describe("overwriteConfigWithCliParam", func() {
		var iConfig *InstallConfig

		BeforeEach(func() {
			iConfig = createInitialInstallConfig()
		})

		DescribeTable("values are correctly overwritten by CLI params", func(flagName string, expected any, getActualFunc func() any) {
			vConfig := viper.New()
			vConfig.Set(flagName, expected)

			overwriteConfigWithCliParam(iConfig, vConfig, flagName)

			Expect(getActualFunc()).To(Equal(expected))
		},
			Entry(common.AdditionalHooksDirFlagName, common.AdditionalHooksDirFlagName, "test-dir", func() any { return iConfig.Env.AdditionalHooksDir }),
			Entry(common.ForceOnlineInstallFlagName, common.ForceOnlineInstallFlagName, false, func() any { return iConfig.Behavior.ForceOnlineInstallation }),
			Entry(common.DeleteFilesFlagName, common.DeleteFilesFlagName, false, func() any { return iConfig.Behavior.DeleteFilesForOfflineInstallation }),
			Entry(common.OutputFlagName, common.OutputFlagName, false, func() any { return iConfig.Behavior.ShowOutput }),
			Entry(AppendLogFlagName, AppendLogFlagName, false, func() any { return iConfig.Behavior.AppendLog }),
			Entry(LinuxOnlyFlagName, LinuxOnlyFlagName, false, func() any { return iConfig.LinuxOnly }),
			Entry(ControlPlaneCPUsFlagName, ControlPlaneCPUsFlagName, "test-cp-cpu", func() any { return iConfig.Nodes[0].Resources.Cpu }),
			Entry(ControlPlaneMemoryFlagName, ControlPlaneMemoryFlagName, "test-cp-memory", func() any { return iConfig.Nodes[0].Resources.Memory }),
			Entry(ControlPlaneDiskSizeFlagName, ControlPlaneDiskSizeFlagName, "test-cp-disk", func() any { return iConfig.Nodes[0].Resources.Disk }),
			Entry(ProxyFlagName, ProxyFlagName, "test-proxy", func() any { return iConfig.Env.Proxy }),
			Entry(SkipStartFlagName, SkipStartFlagName, false, func() any { return iConfig.Behavior.SkipStart }),
			Entry(WslFlagName, WslFlagName, false, func() any { return iConfig.Behavior.Wsl }),
		)
	})

	Describe("ControlPlaneMemoryFlagUsage", func() {
		It("should contain 'minimum 2GB'", func() {
			Expect(ControlPlaneMemoryFlagUsage).To(ContainSubstring("minimum 2GB"))
		})
	})

	Describe("ControlPlaneDiskSizeFlagUsage", func() {
		It("should contain 'minimum 10GB'", func() {
			Expect(ControlPlaneDiskSizeFlagUsage).To(ContainSubstring("minimum 10GB"))
		})
	})

	Describe("validateDynamicMemoryConfiguration", func() {
		When("dynamic memory is disabled", func() {
			It("does not validate", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: false,
								MemoryMin:     "8GB",
								MemoryMax:     "4GB", // Invalid but shouldn't be checked
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).To(BeNil())
			})
		})

		When("min is greater than max", func() {
			It("returns an error", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: true,
								Memory:        "4GB",
								MemoryMin:     "8GB",
								MemoryMax:     "4GB",
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(ContainSubstring("minimum memory (8GB) cannot be greater than maximum memory (4GB)"))
			})
		})

		When("min is greater than startup", func() {
			It("returns an error", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: true,
								Memory:        "4GB",
								MemoryMin:     "6GB",
								MemoryMax:     "8GB",
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(ContainSubstring("minimum memory (6GB) cannot be greater than startup memory (4GB)"))
			})
		})

		When("max is less than startup", func() {
			It("returns an error", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: true,
								Memory:        "6GB",
								MemoryMin:     "2GB",
								MemoryMax:     "4GB",
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).ToNot(BeNil())
				Expect(err.Error()).To(ContainSubstring("maximum memory (4GB) cannot be less than startup memory (6GB)"))
			})
		})

		When("all values are valid", func() {
			It("does not return an error", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: true,
								Memory:        "4GB",
								MemoryMin:     "2GB",
								MemoryMax:     "8GB",
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).To(BeNil())
			})
		})

		When("only max is specified", func() {
			It("does not validate min vs max", func() {
				config := &InstallConfig{
					Nodes: []NodeConfig{
						{
							Role: ControlPlaneRoleName,
							Resources: ResourceConfig{
								DynamicMemory: true,
								Memory:        "4GB",
								MemoryMax:     "8GB",
							},
						},
					},
				}

				err := validateDynamicMemoryConfiguration(config)
				Expect(err).To(BeNil())
			})
		})
	})

	Describe("parseMemorySize", func() {
		DescribeTable("parses memory sizes correctly",
			func(input string, expectedBytes int64) {
				result, err := parseMemorySize(input)
				Expect(err).To(BeNil())
				Expect(result).To(Equal(expectedBytes))
			},
			Entry("GB suffix", "4GB", int64(4*1000*1000*1000)),
			Entry("MB suffix", "512MB", int64(512*1000*1000)),
			Entry("KB suffix", "1024KB", int64(1024*1000)),
			Entry("G suffix (binary)", "4G", int64(4*1024*1024*1024)),
			Entry("M suffix (binary)", "512M", int64(512*1024*1024)),
			Entry("lowercase gb", "4gb", int64(4*1000*1000*1000)),
			Entry("with spaces", " 4GB ", int64(4*1000*1000*1000)),
			Entry("plain number", "1073741824", int64(1073741824)),
			Entry("8GB should not match B", "8GB", int64(8*1000*1000*1000)),
			Entry("6GB should not match B", "6GB", int64(6*1000*1000*1000)),
			Entry("2GB should not match B", "2GB", int64(2*1000*1000*1000)),
		)

		When("input is empty", func() {
			It("returns an error", func() {
				_, err := parseMemorySize("")
				Expect(err).ToNot(BeNil())
			})
		})

		When("input is invalid", func() {
			It("returns an error", func() {
				_, err := parseMemorySize("invalid")
				Expect(err).ToNot(BeNil())
			})
		})

		When("parsing 4GB, 6GB, 8GB in sequence", func() {
			It("returns consistent values", func() {
				val4, err := parseMemorySize("4GB")
				Expect(err).To(BeNil())

				val6, err := parseMemorySize("6GB")
				Expect(err).To(BeNil())

				val8, err := parseMemorySize("8GB")
				Expect(err).To(BeNil())

				// Verify ordering: 4GB < 6GB < 8GB
				Expect(val4).To(BeNumerically("<", val6))
				Expect(val6).To(BeNumerically("<", val8))
				Expect(val4).To(Equal(int64(4 * 1000 * 1000 * 1000)))
				Expect(val6).To(Equal(int64(6 * 1000 * 1000 * 1000)))
				Expect(val8).To(Equal(int64(8 * 1000 * 1000 * 1000)))
			})
		})
	})
})

func createInitialInstallConfig() *InstallConfig {
	return &InstallConfig{
		Kind:       "init-kind",
		ApiVersion: "init-version",
		Env: EnvConfig{
			Proxy:              "init-proxy",
			AdditionalHooksDir: "init-dir",
			RestartPostInstall: "init-restart"},
		LinuxOnly: true,
		Behavior: BehaviorConfig{
			ShowOutput:                        true,
			DeleteFilesForOfflineInstallation: true,
			ForceOnlineInstallation:           true,
			Wsl:                               true,
			AppendLog:                         true,
			SkipStart:                         true},
		Nodes: []NodeConfig{
			{
				Role: ControlPlaneRoleName,
				Resources: ResourceConfig{
					Cpu:    "init-cp-cpu",
					Memory: "init-cp-memory",
					Disk:   "init-cp-disk",
				}},
		}}
}

func readTestConfig() ([]byte, error) {
	return os.ReadFile(testConfigFilePath)
}
