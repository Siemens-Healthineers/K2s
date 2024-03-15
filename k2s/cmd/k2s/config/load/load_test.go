// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	"github.com/siemens-healthineers/k2s/internal/reflection"

	cd "github.com/siemens-healthineers/k2s/cmd/k2s/config/defs"
	"github.com/siemens-healthineers/k2s/cmd/k2s/config/load"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/stretchr/testify/mock"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) readFile(filename string) ([]byte, error) {
	args := m.Called(filename)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *mockObject) isFileNotExist(err error) bool {
	args := m.Called(err)

	return args.Bool(0)
}

func (m *mockObject) unmarshal(data []byte, v any) error {
	args := m.Called(data, v)

	return args.Error(0)
}

func TestLoad(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "load Unit Tests", Label("unit", "ci", "load"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("load", func() {
	Describe("Load", func() {
		When("file read error occurred", func() {
			It("returns the error", func() {
				path := "some-path"
				expectedErr := errors.New("oops")

				readerMock := &mockObject{}
				readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return([]byte{}, expectedErr)

				sut := load.NewConfigLoader(readerMock.readFile, nil, nil)

				actual, err := sut.Load(path)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedErr))
			})
		})

		When("unmarshal error occurred", func() {
			It("returns the error", func() {
				path := "some-path"
				expectedErr := errors.New("oops")
				data := []byte{0, 1, 2}

				readerMock := &mockObject{}
				readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return(data, nil)

				umMock := &mockObject{}
				umMock.On(reflection.GetFunctionName(umMock.unmarshal), data, mock.Anything).Return(expectedErr)

				sut := load.NewConfigLoader(readerMock.readFile, nil, umMock.unmarshal)

				actual, err := sut.Load(path)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedErr))
			})
		})

		It("returns correct result", func() {
			path := "some-path"
			data := []byte{0, 1, 2}
			expectedConfig := &cd.Config{SmallSetup: cd.SmallSetupConfig{ConfigDir: cd.ConfigDir{Kube: "test"}}}

			readerMock := &mockObject{}
			readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return(data, nil)

			umMock := &mockObject{}
			umMock.On(reflection.GetFunctionName(umMock.unmarshal), data, mock.Anything).Run(func(args mock.Arguments) {
				p := args.Get(1).(**cd.Config)
				*p = expectedConfig
			}).Return(nil)

			sut := load.NewConfigLoader(readerMock.readFile, nil, umMock.unmarshal)

			actual, err := sut.Load(path)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).ToNot(BeNil())
			Expect(actual.SmallSetup.ConfigDir.Kube).To(Equal(expectedConfig.SmallSetup.ConfigDir.Kube))
		})
	})

	Describe("LoadForSetup", func() {
		When("file read error occurred", func() {
			It("returns the error", func() {
				path := "some-path"
				expectedErr := errors.New("oops")

				readerMock := &mockObject{}
				readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return([]byte{}, expectedErr)

				checkMock := &mockObject{}
				checkMock.On(reflection.GetFunctionName(checkMock.isFileNotExist), expectedErr).Return(false)

				sut := load.NewConfigLoader(readerMock.readFile, checkMock.isFileNotExist, nil)

				actual, err := sut.LoadForSetup(path)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedErr))
			})
		})

		When("file-non-existent error occurred", func() {
			It("returns the system-not-installed-error", func() {
				path := "some-path"
				errNotExist := errors.New("gone")

				readerMock := &mockObject{}
				readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return([]byte{}, errNotExist)

				checkMock := &mockObject{}
				checkMock.On(reflection.GetFunctionName(checkMock.isFileNotExist), errNotExist).Return(true)

				sut := load.NewConfigLoader(readerMock.readFile, checkMock.isFileNotExist, nil)

				actual, err := sut.LoadForSetup(path)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(setupinfo.ErrSystemNotInstalled))
			})
		})

		When("unmarshal error occurred", func() {
			It("returns the error", func() {
				path := "some-path"
				expectedErr := errors.New("oops")
				data := []byte{0, 1, 2}

				readerMock := &mockObject{}
				readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return(data, nil)

				checkMock := &mockObject{}
				checkMock.On(reflection.GetFunctionName(checkMock.isFileNotExist), expectedErr).Return(false)

				umMock := &mockObject{}
				umMock.On(reflection.GetFunctionName(umMock.unmarshal), data, mock.Anything).Return(expectedErr)

				sut := load.NewConfigLoader(readerMock.readFile, checkMock.isFileNotExist, umMock.unmarshal)

				actual, err := sut.LoadForSetup(path)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(expectedErr))
			})
		})

		It("returns correct result", func() {
			path := "some-path"
			data := []byte{0, 1, 2}
			expectedConfig := &cd.SetupConfig{SetupName: "test"}

			readerMock := &mockObject{}
			readerMock.On(reflection.GetFunctionName(readerMock.readFile), path).Return(data, nil)

			checkMock := &mockObject{}
			checkMock.On(reflection.GetFunctionName(checkMock.isFileNotExist), nil).Return(false)

			umMock := &mockObject{}
			umMock.On(reflection.GetFunctionName(umMock.unmarshal), data, mock.Anything).Run(func(args mock.Arguments) {
				p := args.Get(1).(**cd.SetupConfig)
				*p = expectedConfig
			}).Return(nil)

			sut := load.NewConfigLoader(readerMock.readFile, checkMock.isFileNotExist, umMock.unmarshal)

			actual, err := sut.LoadForSetup(path)

			Expect(err).ToNot(HaveOccurred())
			Expect(actual).ToNot(BeNil())
			Expect(actual.SetupName).To(Equal(expectedConfig.SetupName))
		})
	})
})
