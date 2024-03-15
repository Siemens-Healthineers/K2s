// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package path_test

import (
	"errors"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/config/path"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type mockObject struct {
	mock.Mock
}

func (m *mockObject) getUserHomeDir() (string, error) {
	args := m.Called()

	return args.String(0), args.Error(1)
}

func TestPath(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "path Unit Tests", Label("unit", "ci", "path"))
}

var _ = Describe("path", func() {
	Describe("Build", func() {
		When("home dir determination error occurred", func() {
			It("returns the error", func() {
				inputDir := "~/relative-path"
				expectedError := errors.New("oops")

				dirMock := &mockObject{}
				dirMock.On(reflection.GetFunctionName(dirMock.getUserHomeDir)).Return("", expectedError)

				sut := path.NewSetupConfigPathBuilder(dirMock.getUserHomeDir)

				actual, err := sut.Build(inputDir, "some file name")

				Expect(err).To(MatchError(expectedError))
				Expect(actual).To(BeEmpty())
			})
		})

		When("successful", func() {
			It("converts relative home dir to absolute home dir", func() {
				inputDir := "~/my-relative-dir"
				inputFileName := "my-file.ext"
				expectedHomeDir := `a:\b\c\`
				expected := `a:\b\c\my-relative-dir\my-file.ext`

				dirMock := &mockObject{}
				dirMock.On(reflection.GetFunctionName(dirMock.getUserHomeDir)).Return(expectedHomeDir, nil)

				sut := path.NewSetupConfigPathBuilder(dirMock.getUserHomeDir)

				actual, err := sut.Build(inputDir, inputFileName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})

			It("builds path correctly", func() {
				inputDir := `a:\b\c\my-dir`
				inputFileName := "my-file.ext"
				expected := `a:\b\c\my-dir\my-file.ext`

				sut := path.NewSetupConfigPathBuilder(nil)

				actual, err := sut.Build(inputDir, inputFileName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
