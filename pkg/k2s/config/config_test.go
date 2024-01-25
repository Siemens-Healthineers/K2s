// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"errors"
	"testing"

	cd "k2s/config/defs"
	"k2s/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type testLoader struct {
	resultConfig      *cd.Config
	resultSetupConfig *cd.SetupConfig
	resultKubeConfig  *cd.KubeConfig
	err               error
}

type testBuilder struct {
	result string
	err    error
}

func (t testLoader) Load(path string) (config *cd.Config, err error) {
	return t.resultConfig, t.err
}

func (t testLoader) LoadForSetup(filePath string) (config *cd.SetupConfig, err error) {
	return t.resultSetupConfig, t.err
}

func (t testLoader) LoadForKube(filePath string) (*cd.KubeConfig, error) {
	return t.resultKubeConfig, t.err
}

func (t testBuilder) Build(configDir string, configFileName string) (configPath string, err error) {
	return t.result, t.err
}

func TestConfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "config Unit Tests", Label("unit"))
}

var _ = Describe("config", func() {
	Describe("SmallSetupDir", func() {
		When("called on instance", func() {
			It("returns correct value", func() {
				sut := NewConfigAccess(testLoader{}, testBuilder{})

				actual := sut.SmallSetupDir()

				Expect(actual).To(Equal(smallSetupDir))
			})
		})

		When("called without instance", func() {
			It("returns correct value", func() {
				smallSetupDir = "my dir"

				actual := SmallSetupDir()

				Expect(actual).To(Equal(smallSetupDir))
			})
		})
	})

	Describe("GetSetupName", func() {
		When("already determined", func() {
			It("returns setup name without file access", func() {
				expected := setupinfo.SetupNameMultiVMK8s
				config := &cd.SetupConfig{
					SetupName: expected,
				}
				loader := &testLoader{}
				sut := NewConfigAccess(loader, nil)
				sut.setupConfig = config

				actual, err := sut.GetSetupName()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("config load error occurred", func() {
			It("returns the error", func() {
				loader := &testLoader{err: errors.New("oops")}
				sut := NewConfigAccess(loader, nil)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(loader.err))
				Expect(actual).To(BeEmpty())
			})
		})

		When("config path build error occurred", func() {
			It("returns the error", func() {
				inputConfig := &cd.Config{
					SmallSetup: cd.SmallSetupConfig{
						ConfigDir: cd.ConfigDir{
							Kube: ""}},
				}
				loader := &testLoader{resultConfig: inputConfig}
				builder := &testBuilder{err: errors.New("oops")}
				sut := NewConfigAccess(loader, builder)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(builder.err))
				Expect(actual).To(BeEmpty())
			})
		})

		When("setup config load error occurred", func() {
			It("returns the error", func() {
				inputConfig := &cd.Config{
					SmallSetup: cd.SmallSetupConfig{
						ConfigDir: cd.ConfigDir{
							Kube: ""}},
				}
				loader := &testLoader{resultConfig: inputConfig, err: errors.New("oops")}
				builder := &testBuilder{}
				sut := NewConfigAccess(loader, builder)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(loader.err))
				Expect(actual).To(BeEmpty())
			})
		})

		When("successful", func() {
			It("returns the correct result", func() {
				var expected setupinfo.SetupName = "correct name"
				inputConfig := &cd.Config{
					SmallSetup: cd.SmallSetupConfig{
						ConfigDir: cd.ConfigDir{
							Kube: ""}},
				}
				inputSetupConfig := &cd.SetupConfig{SetupName: expected}
				loader := &testLoader{resultConfig: inputConfig, resultSetupConfig: inputSetupConfig}
				builder := &testBuilder{}
				sut := NewConfigAccess(loader, builder)

				actual, err := sut.GetSetupName()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
