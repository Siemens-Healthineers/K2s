// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package system_test

import (
	"base/system"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Base System Integration Tests", Label("integration", "system"))
}

var _ = Describe("SystemDrive", func() {
	It("returns Windows system drive with trailing backslash", func() {
		drive := system.SystemDrive()

		Expect(drive).To(Equal("C:\\"))
	})
})
