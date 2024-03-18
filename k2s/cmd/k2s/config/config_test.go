// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"errors"
	"testing"

	cd "github.com/siemens-healthineers/k2s/cmd/k2s/config/defs"
	"github.com/stretchr/testify/mock"

	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) Load(path string) (config *cd.Config, err error) {
	args := m.Called(path)

	return args.Get(0).(*cd.Config), args.Error(1)
}

func (m *mockObject) LoadForSetup(filePath string) (config *cd.SetupConfig, err error) {
	args := m.Called(filePath)

	return args.Get(0).(*cd.SetupConfig), args.Error(1)
}

func (m *mockObject) Build(configDir string, configFileName string) (configPath string, err error) {
	args := m.Called(configDir, configFileName)

	return args.String(0), args.Error(1)
}

func TestConfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "config Unit Tests", Label("unit", "ci"))
}

var _ = Describe("config", func() {
	Describe("GetSetupName", func() {
		When("already determined", func() {
			It("returns setup name without file access", func() {
				expected := setupinfo.SetupNameMultiVMK8s
				config := &cd.SetupConfig{
					SetupName: expected,
				}
				loaderMock := &mockObject{}

				sut := NewConfigAccess(loaderMock, nil)
				sut.setupConfig = config

				actual, err := sut.GetSetupName()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("config load error occurred", func() {
			It("returns the error", func() {
				expectedErr := errors.New("oops")

				loaderMock := &mockObject{}
				loaderMock.On(reflection.GetFunctionName(loaderMock.Load), mock.AnythingOfType("string")).Return(&cd.Config{}, expectedErr)

				sut := NewConfigAccess(loaderMock, nil)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(expectedErr))
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
				expectedErr := errors.New("oops")

				loaderMock := &mockObject{}
				loaderMock.On(reflection.GetFunctionName(loaderMock.Load), mock.AnythingOfType("string")).Return(inputConfig, nil)

				builderMock := &mockObject{}
				builderMock.On(reflection.GetFunctionName(builderMock.Build), mock.AnythingOfType("string"), mock.AnythingOfType("string")).Return("", expectedErr)

				sut := NewConfigAccess(loaderMock, builderMock)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(expectedErr))
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
				path := "some-path"

				expectedErr := errors.New("oops")

				loaderMock := &mockObject{}
				loaderMock.On(reflection.GetFunctionName(loaderMock.Load), mock.AnythingOfType("string")).Return(inputConfig, nil)
				loaderMock.On(reflection.GetFunctionName(loaderMock.LoadForSetup), path).Return(&cd.SetupConfig{}, expectedErr)

				builderMock := &mockObject{}
				builderMock.On(reflection.GetFunctionName(builderMock.Build), mock.AnythingOfType("string"), mock.AnythingOfType("string")).Return(path, nil)

				sut := NewConfigAccess(loaderMock, builderMock)

				actual, err := sut.GetSetupName()

				Expect(err).To(MatchError(expectedErr))
				Expect(actual).To(BeEmpty())
			})
		})

		When("successful", func() {
			It("returns the correct result", func() {
				expected := setupinfo.SetupName("correct name")
				inputConfig := &cd.Config{
					SmallSetup: cd.SmallSetupConfig{
						ConfigDir: cd.ConfigDir{
							Kube: ""}},
				}
				inputSetupConfig := &cd.SetupConfig{SetupName: expected}

				path := "some-path"

				loaderMock := &mockObject{}
				loaderMock.On(reflection.GetFunctionName(loaderMock.Load), mock.AnythingOfType("string")).Return(inputConfig, nil)
				loaderMock.On(reflection.GetFunctionName(loaderMock.LoadForSetup), path).Return(inputSetupConfig, nil)

				builderMock := &mockObject{}
				builderMock.On(reflection.GetFunctionName(builderMock.Build), mock.AnythingOfType("string"), mock.AnythingOfType("string")).Return(path, nil)

				sut := NewConfigAccess(loaderMock, builderMock)

				actual, err := sut.GetSetupName()

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
