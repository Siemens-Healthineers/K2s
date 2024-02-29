// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package path_test

import (
	"errors"
	"testing"

	"k2s/config/path"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type testDirProvider struct {
	result string
	err    error
}

func (t testDirProvider) GetUserHomeDir() (string, error) {
	return t.result, t.err
}

func TestPath(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "path Unit Tests", Label("unit", "ci"))
}

var _ = Describe("path", func() {
	Describe("Build", func() {
		When("home dir determination error occurred", func() {
			It("returns the error", func() {
				inputDir := "~/relative-path"
				dirProvider := testDirProvider{err: errors.New("oops")}
				sut := path.NewSetupConfigPathBuilder(dirProvider)

				actual, err := sut.Build(inputDir, "some file name")

				Expect(err).To(MatchError(dirProvider.err))
				Expect(actual).To(BeEmpty())
			})
		})

		When("successful", func() {
			It("converts relative home dir to absolute home dir", func() {
				inputDir := "~/my-relative-dir"
				inputFileName := "my-file.ext"
				expectedHomeDir := `a:\b\c\`
				expected := `a:\b\c\my-relative-dir\my-file.ext`
				provider := testDirProvider{result: expectedHomeDir}
				sut := path.NewSetupConfigPathBuilder(provider)

				actual, err := sut.Build(inputDir, inputFileName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})

			It("builds path correctly", func() {
				inputDir := `a:\b\c\my-dir`
				inputFileName := "my-file.ext"
				expected := `a:\b\c\my-dir\my-file.ext`
				sut := path.NewSetupConfigPathBuilder(testDirProvider{})

				actual, err := sut.Build(inputDir, inputFileName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})
