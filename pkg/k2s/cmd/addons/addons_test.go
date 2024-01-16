// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"fmt"
	"k2s/addons"
	"k2s/cmd/params"
	"test/reflection"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/pflag"
	"github.com/stretchr/testify/mock"
	"k8s.io/klog/v2"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) add(p string) {
	m.Called(p)
}

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons cmd Unit Tests", Label("unit"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("addons", func() {
	Describe("createGenericCommands", func() {
		When("command names slice is empty", func() {
			It("returns empty slice", func() {
				addons := addons.Addons{}
				commands := []string{}

				result, err := createGenericCommands(addons, commands...)

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(BeEmpty())
			})
		})

		When("command names exist", func() {
			It("returns one command per command name", func() {
				addons := addons.Addons{}
				commands := []string{"do-this", "do-that"}

				result, err := createGenericCommands(addons, commands...)

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(HaveLen(len(commands)))
				Expect(result[0].Use).To(Equal(commands[0]))
				Expect(result[0].Short).To(ContainSubstring(commands[0]))
				Expect(result[1].Use).To(Equal(commands[1]))
				Expect(result[1].Short).To(ContainSubstring(commands[1]))
			})
		})

		When("error occurred", func() {
			It("returns error", func() {
				command := "do-this"
				addons := addons.Addons{
					addons.Addon{
						Spec: addons.AddonSpec{
							Commands: &map[string]addons.AddonCmd{
								command: {
									Cli: &addons.CliConfig{
										Flags: []addons.CliFlag{
											{
												Default: []string{"invalid-type"},
											},
										},
									},
								},
							},
						},
					},
				}

				result, err := createGenericCommands(addons, command)

				Expect(err).To(HaveOccurred())
				Expect(result).To(BeEmpty())
			})
		})
	})

	Describe("createGenericCommand", func() {
		When("no addons passed", func() {
			It("returns command without sub-commands", func() {
				command := "do-this"
				addons := addons.Addons{}

				result, err := createGenericCommand(addons, command)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Use).To(Equal(command))
				Expect(result.Short).To(ContainSubstring(command))
				Expect(result.Commands()).To(BeEmpty())
			})
		})

		When("addons passed", func() {
			It("returns command with one sub-command per addon", func() {
				command := "do-this"
				addons := addons.Addons{
					addons.Addon{
						Metadata: addons.AddonMetadata{
							Name: "a1",
						},
						Spec: addons.AddonSpec{Commands: &map[string]addons.AddonCmd{
							command: {},
						}},
					},
					addons.Addon{
						Metadata: addons.AddonMetadata{
							Name: "a2",
						},
						Spec: addons.AddonSpec{Commands: &map[string]addons.AddonCmd{
							command: {},
						}},
					},
				}

				result, err := createGenericCommand(addons, command)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Use).To(Equal(command))
				Expect(result.Short).To(ContainSubstring(command))
				Expect(result.Commands()).To(HaveLen(len(addons)))
			})
		})

		When("error occurred", func() {
			It("returns error", func() {
				command := "do-this"
				addons := addons.Addons{
					addons.Addon{
						Spec: addons.AddonSpec{
							Commands: &map[string]addons.AddonCmd{
								command: {
									Cli: &addons.CliConfig{
										Flags: []addons.CliFlag{
											{
												Default: []string{"invalid-type"},
											},
										},
									},
								},
							},
						},
					},
				}

				result, err := createGenericCommand(addons, command)

				Expect(err).To(HaveOccurred())
				Expect(result).To(BeNil())
			})
		})
	})

	Describe("newAddonCmd", func() {
		When("no CLI config exists", func() {
			It("returns command without flags or examples", func() {
				command := "do-this"
				addon := addons.Addon{
					Metadata: addons.AddonMetadata{
						Name: "a1",
					},
					Spec: addons.AddonSpec{
						Commands: &map[string]addons.AddonCmd{
							command: {},
						},
					},
				}

				result, err := newAddonCmd(addon, command)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Use).To(Equal(addon.Metadata.Name))
				Expect(result.Short).To(SatisfyAll(ContainSubstring(command), ContainSubstring(addon.Metadata.Name)))
				Expect(result.RunE).ToNot(BeNil())
				Expect(result.Example).To(BeEmpty())
				Expect(result.HasFlags()).To(BeFalse())
			})
		})

		When("CLI config exists with examples", func() {
			It("returns command with examples", func() {
				command := "do-this"
				comment := "this is a comment"
				addon := addons.Addon{
					Metadata: addons.AddonMetadata{
						Name: "a1",
					},
					Spec: addons.AddonSpec{
						Commands: &map[string]addons.AddonCmd{
							command: {
								Cli: &addons.CliConfig{
									Examples: addons.CliExamples{
										addons.CliExample{
											Cmd:     command,
											Comment: &comment,
										},
									},
								},
							},
						},
					},
				}

				result, err := newAddonCmd(addon, command)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Use).To(Equal(addon.Metadata.Name))
				Expect(result.Short).To(SatisfyAll(ContainSubstring(command), ContainSubstring(addon.Metadata.Name)))
				Expect(result.RunE).ToNot(BeNil())
				Expect(result.Example).To(SatisfyAll(
					ContainSubstring((*addon.Spec.Commands)[command].Cli.Examples[0].Cmd),
					ContainSubstring(*(*addon.Spec.Commands)[command].Cli.Examples[0].Comment),
				))
				Expect(result.HasFlags()).To(BeFalse())
			})
		})

		When("CLI config exists with flags", func() {
			It("returns command with flags", func() {
				command := "do-this"
				flagName := "test-flag"
				flagValue := "test-flag"
				addon := addons.Addon{
					Metadata: addons.AddonMetadata{
						Name: "a1",
					},
					Spec: addons.AddonSpec{
						Commands: &map[string]addons.AddonCmd{
							command: {
								Cli: &addons.CliConfig{
									Flags: []addons.CliFlag{
										{
											Name:    flagName,
											Default: flagValue,
										},
									},
								},
							},
						},
					},
				}

				result, err := newAddonCmd(addon, command)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Use).To(Equal(addon.Metadata.Name))
				Expect(result.Short).To(SatisfyAll(ContainSubstring(command), ContainSubstring(addon.Metadata.Name)))
				Expect(result.RunE).ToNot(BeNil())
				Expect(result.Example).To(BeEmpty())
				Expect(result.HasFlags()).To(BeTrue())

				value, err := result.Flags().GetString(flagName)

				Expect(err).ToNot(HaveOccurred())
				Expect(value).To(Equal(flagValue))
			})
		})

		When("error occurred", func() {
			It("returns error", func() {
				command := "do-this"
				addon := addons.Addon{
					Spec: addons.AddonSpec{
						Commands: &map[string]addons.AddonCmd{
							command: {
								Cli: &addons.CliConfig{
									Flags: []addons.CliFlag{
										{
											Default: []string{"invalid-type"},
										},
									},
								},
							},
						},
					},
				}

				result, err := newAddonCmd(addon, command)

				Expect(err).To(HaveOccurred())
				Expect(result).To(BeNil())
			})
		})
	})

	Describe("addFlag", func() {
		When("flag value type is invalid", func() {
			It("returns error", func() {
				flag := addons.CliFlag{Default: []string{"invalid-type"}}
				flagSet := &pflag.FlagSet{}

				Expect(addFlag(flag, flagSet)).ToNot(Succeed())
			})
		})

		When("flag value type is string", func() {
			When("shorthand does not exist", func() {
				It("adds string flag without shorthand", func() {
					description := "test-description"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     "test-value",
						Description: &description,
						Constraints: &addons.Constraints{
							Kind:          addons.ValidationSetConstraintsType,
							ValidationSet: &addons.ValidationSet{"test-value"},
						},
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(flag.Default))
					Expect(pflag.Usage).To(SatisfyAll(
						ContainSubstring(description),
						ContainSubstring(fmt.Sprintf("[%s]", flag.Default)),
					))
					Expect(pflag.Value.Type()).To(Equal("string"))
				})
			})

			When("shorthand exists", func() {
				It("adds string flag with shorthand", func() {
					description := "test-description"
					shorthand := "t"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     "test-value",
						Description: &description,
						Constraints: &addons.Constraints{
							Kind:          addons.ValidationSetConstraintsType,
							ValidationSet: &addons.ValidationSet{"test-value"},
						},
						Shorthand: &shorthand,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(flag.Default))
					Expect(pflag.Usage).To(SatisfyAll(
						ContainSubstring(description),
						ContainSubstring(fmt.Sprintf("[%s]", flag.Default)),
					))
					Expect(pflag.Value.Type()).To(Equal("string"))
					Expect(pflag.Shorthand).To(Equal(*flag.Shorthand))
				})
			})
		})

		When("flag value type is bool", func() {
			When("shorthand does not exist", func() {
				It("adds bool flag without shorthand", func() {
					description := "test-description"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     true,
						Description: &description,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("bool"))
				})
			})

			When("shorthand exists", func() {
				It("adds bool flag with shorthand", func() {
					description := "test-description"
					shorthand := "t"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     true,
						Description: &description,
						Shorthand:   &shorthand,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("bool"))
					Expect(pflag.Shorthand).To(Equal(*flag.Shorthand))
				})
			})
		})

		When("flag value type is int", func() {
			When("shorthand does not exist", func() {
				It("adds int flag without shorthand", func() {
					description := "test-description"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     123,
						Description: &description,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("int"))
				})
			})

			When("shorthand exists", func() {
				It("adds int flag with shorthand", func() {
					description := "test-description"
					shorthand := "t"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     123,
						Description: &description,
						Shorthand:   &shorthand,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("int"))
					Expect(pflag.Shorthand).To(Equal(*flag.Shorthand))
				})
			})
		})

		When("flag value type is float64", func() {
			When("shorthand does not exist", func() {
				It("adds float64 flag without shorthand", func() {
					description := "test-description"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     123.45,
						Description: &description,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("float64"))
				})
			})

			When("shorthand exists", func() {
				It("adds float64 flag with shorthand", func() {
					description := "test-description"
					shorthand := "t"
					flag := addons.CliFlag{
						Name:        "test-flag",
						Default:     123.45,
						Description: &description,
						Shorthand:   &shorthand,
					}
					flagSet := &pflag.FlagSet{}

					Expect(addFlag(flag, flagSet)).To(Succeed())

					pflag := flagSet.Lookup(flag.Name)

					Expect(pflag).ToNot(BeNil())
					Expect(pflag.Value.String()).To(Equal(fmt.Sprint(flag.Default)))
					Expect(pflag.Usage).To(Equal(description))
					Expect(pflag.Value.Type()).To(Equal("float64"))
					Expect(pflag.Shorthand).To(Equal(*flag.Shorthand))
				})
			})
		})
	})

	Describe("buildPsCmd", func() {
		When("no flags exist", func() {
			It("builds script command without params", func() {
				dir := "test-dir"
				cmd := addons.AddonCmd{
					Script: addons.ScriptConfig{
						SubPath: "test.script",
					},
				}
				flagSet := &pflag.FlagSet{}

				result, err := buildPsCmd(flagSet, cmd, dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(Equal("&'test-dir\\test.script'"))
			})
		})

		When("flags exist, but an error occurred", func() {
			It("returns the error and skips remaining flags", func() {
				maliciousFlagName := "malicious flag"
				normalFlagName := "normal flag"
				dir := "test-dir"
				cmd := addons.AddonCmd{
					Cli: &addons.CliConfig{
						Flags: []addons.CliFlag{
							{
								Name:    maliciousFlagName,
								Default: "",
								Constraints: &addons.Constraints{
									Kind:          addons.ValidationSetConstraintsType,
									ValidationSet: &addons.ValidationSet{"valid"},
								},
							},
							{
								Name:    normalFlagName,
								Default: "",
							},
						},
					},
					Script: addons.ScriptConfig{
						SubPath: "test.script",
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName: maliciousFlagName,
							},
							{
								CliFlagName:         normalFlagName,
								ScriptParameterName: "should-not-be-used",
							},
						},
					},
				}
				flagSet := &pflag.FlagSet{}
				flagSet.String(maliciousFlagName, "", "")
				flagSet.String(normalFlagName, "", "")

				Expect(flagSet.Set(maliciousFlagName, "invalid")).To(Succeed())
				Expect(flagSet.Set(normalFlagName, "valid")).To(Succeed())

				result, err := buildPsCmd(flagSet, cmd, dir)

				Expect(err).To(HaveOccurred())
				Expect(result).To(Equal("&'test-dir\\test.script'"))
			})
		})

		When("valid flags exist", func() {
			It("builds script command with params", func() {
				flag1Name := "f1"
				flag2Name := "f2"
				dir := "test-dir"
				cmd := addons.AddonCmd{
					Cli: &addons.CliConfig{
						Flags: []addons.CliFlag{
							{
								Name:    flag1Name,
								Default: "",
							},
							{
								Name:    flag2Name,
								Default: "",
							},
						},
					},
					Script: addons.ScriptConfig{
						SubPath: "test.script",
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flag1Name,
								ScriptParameterName: "p1",
							},
							{
								CliFlagName:         flag2Name,
								ScriptParameterName: "p2",
							},
						},
					},
				}
				flagSet := &pflag.FlagSet{}
				flagSet.String(flag1Name, "", "")
				flagSet.String(flag2Name, "", "")

				Expect(flagSet.Set(flag1Name, "v1")).To(Succeed())
				Expect(flagSet.Set(flag2Name, "v2")).To(Succeed())

				result, err := buildPsCmd(flagSet, cmd, dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(result).To(Equal("&'test-dir\\test.script' -p1 v1 -p2 v2"))
			})
		})
	})

	Describe("convertToPsParam", func() {
		When("flag is nil", func() {
			It("returns an error", func() {
				cmd := addons.AddonCmd{}

				err := convertToPsParam(nil, cmd, nil)

				Expect(err).To(MatchError(ContainSubstring("flag must not be nil")))
			})
		})

		When("flag is global output flag", func() {
			It("adds output param", func() {
				flag := &pflag.Flag{Name: params.OutputFlagName}
				cmd := addons.AddonCmd{}
				addMock := &mockObject{}
				addMock.On(reflection.GetFunctionName(addMock.add), "-ShowLogs").Once()

				Expect(convertToPsParam(flag, cmd, addMock.add)).To(Succeed())

				addMock.AssertExpectations(GinkgoT())
			})
		})

		When("flag not found in parameter mapping", func() {
			It("does nothing", func() {
				flag := &pflag.Flag{Name: "not-in-mapping"}
				cmd := addons.AddonCmd{Script: addons.ScriptConfig{}}

				Expect(convertToPsParam(flag, cmd, nil)).To(Succeed())
			})
		})

		When("flag is bool", func() {
			It("adds output param as switch", func() {
				flagName := "bool-flag"
				flagSet := &pflag.FlagSet{}
				flagSet.Bool(flagName, true, "")
				flag := flagSet.Lookup(flagName)

				cmd := addons.AddonCmd{
					Script: addons.ScriptConfig{
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flagName,
								ScriptParameterName: "TestSwitch",
							},
						},
					},
				}
				addMock := &mockObject{}
				addMock.On(reflection.GetFunctionName(addMock.add), "-TestSwitch").Once()

				Expect(convertToPsParam(flag, cmd, addMock.add)).To(Succeed())

				addMock.AssertExpectations(GinkgoT())
			})
		})

		When("CLI config is missing", func() {
			It("returns an error", func() {
				flagName := "string-flag"
				flagSet := &pflag.FlagSet{}
				flagSet.String(flagName, "value", "")
				flag := flagSet.Lookup(flagName)

				cmd := addons.AddonCmd{
					Script: addons.ScriptConfig{
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flagName,
								ScriptParameterName: "TestStringValue",
							},
						},
					},
				}

				err := convertToPsParam(flag, cmd, nil)

				Expect(err).To(MatchError(ContainSubstring("CLI config must not be nil")))
			})
		})

		When("flag name not found in CLI config", func() {
			It("returns an error", func() {
				flagName := "string-flag"
				flagSet := &pflag.FlagSet{}
				flagSet.String(flagName, "value", "")
				flag := flagSet.Lookup(flagName)

				cmd := addons.AddonCmd{
					Cli: &addons.CliConfig{},
					Script: addons.ScriptConfig{
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flagName,
								ScriptParameterName: "TestStringValue",
							},
						},
					},
				}

				err := convertToPsParam(flag, cmd, nil)

				Expect(err).To(MatchError(ContainSubstring("flag config not found")))
			})
		})

		When("flag value is invalid", func() {
			It("returns the validation error", func() {
				flagName := "string-flag"
				flagSet := &pflag.FlagSet{}
				flagSet.String(flagName, "invalid-value", "")
				flag := flagSet.Lookup(flagName)

				cmd := addons.AddonCmd{
					Cli: &addons.CliConfig{
						Flags: []addons.CliFlag{
							{
								Name: flagName,
								Constraints: &addons.Constraints{
									Kind:          addons.ValidationSetConstraintsType,
									ValidationSet: &addons.ValidationSet{"valid-value"},
								},
							},
						},
					},
					Script: addons.ScriptConfig{
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flagName,
								ScriptParameterName: "TestStringValue",
							},
						},
					},
				}

				err := convertToPsParam(flag, cmd, nil)

				Expect(err).To(MatchError(ContainSubstring("validation error")))
			})
		})

		When("flag value is valid and non-boolean", func() {
			It("adds output param with value", func() {
				flagName := "string-flag"
				flagSet := &pflag.FlagSet{}
				flagSet.String(flagName, "test-value", "")
				flag := flagSet.Lookup(flagName)

				cmd := addons.AddonCmd{
					Cli: &addons.CliConfig{
						Flags: []addons.CliFlag{
							{
								Name: flagName,
							}},
					},
					Script: addons.ScriptConfig{
						ParameterMappings: []addons.ParameterMapping{
							{
								CliFlagName:         flagName,
								ScriptParameterName: "TestStringValue",
							},
						},
					},
				}

				addMock := &mockObject{}
				addMock.On(reflection.GetFunctionName(addMock.add), "-TestStringValue test-value").Once()

				Expect(convertToPsParam(flag, cmd, addMock.add)).To(Succeed())

				addMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
