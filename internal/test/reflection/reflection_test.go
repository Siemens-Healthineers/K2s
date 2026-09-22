// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package reflection_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/test/reflection"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "reflection pkg Unit Tests", Label("unit", "ci", "test", "reflection"))
}

var _ = Describe("reflection pkg", func() {
	Describe("GetFunctionName", func() {
		It("returns function name", func() {
			actual := reflection.GetFunctionName(reflection.GetFunctionName)

			Expect(actual).To(Equal("GetFunctionName"))
		})
	})
})
