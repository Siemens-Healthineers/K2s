// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package json_test

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	j "encoding/json"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/json"
)

func TestJsonPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "json pkg Integration Tests", Label("integration", "ci", "json"))
}

type testData struct {
	Prop1 string `json:"prop1"`
	Prop2 int    `json:"prop2"`
}

var _ = Describe("json pkg", func() {
	Describe("MarshalIndent", func() {
		It("returns indented json", func() {
			input := testData{
				Prop1: "test-prop",
				Prop2: 123,
			}
			expected := "{\n  \"prop1\": \"test-prop\",\n  \"prop2\": 123\n}"

			actual, err := json.MarshalIndent(input)

			Expect(err).ToNot(HaveOccurred())
			Expect(string(actual)).To(Equal(expected))
		})
	})

	Describe("FromFile", func() {
		When("file read error occurrs", func() {
			It("returns the error", func() {
				nonExistentFile := filepath.Join(GinkgoT().TempDir(), "non-existent")

				actual, err := json.FromFile[testData](nonExistentFile)

				Expect(err).To(MatchError(os.ErrNotExist))
				Expect(actual).To(BeNil())
			})
		})

		When("unmarshal error occurrs", func() {
			var filePath string

			BeforeEach(func() {
				content := "nonsense"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")

				file, err := os.OpenFile(filePath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(content))
				Expect(err).ToNot(HaveOccurred())

				err = file.Close()
				Expect(err).ToNot(HaveOccurred())
			})

			It("returns the error", func() {
				actual, err := json.FromFile[testData](filePath)

				var syntaxErr *j.SyntaxError
				Expect(errors.As(err, &syntaxErr)).To(BeTrue())
				Expect(actual).To(BeNil())
			})
		})

		When("successful", func() {
			var filePath string

			BeforeEach(func() {
				content := "{\"prop1\": \"test-prop\", \"prop2\": 123}"
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")

				file, err := os.OpenFile(filePath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(content))
				Expect(err).ToNot(HaveOccurred())

				err = file.Close()
				Expect(err).ToNot(HaveOccurred())
			})

			It("returns the json file content", func() {
				expected := testData{Prop1: "test-prop", Prop2: 123}

				actual, err := json.FromFile[testData](filePath)

				Expect(err).ToNot(HaveOccurred())
				Expect(*actual).To(Equal(expected))
			})
		})
	})

	Describe("ToFile", func() {
		When("successful", func() {
			var filePath string

			BeforeEach(func() {
				filePath = filepath.Join(GinkgoT().TempDir(), "test.json")
			})

			It("writes and reads the json file content", func() {
				expected := &testData{Prop1: "test-prop", Prop2: 123}

				err := json.ToFile[testData](filePath, expected)

				actual, err := json.FromFile[testData](filePath)

				Expect(err).ToNot(HaveOccurred())
				Expect(*actual).To(Equal(*expected))
			})
		})
	})
})
