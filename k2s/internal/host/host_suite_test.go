// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/host"
)

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Base System Integration Tests", Label("integration", "system"))
}

var _ = Describe("SystemDrive", func() {
	It("returns Windows system drive with trailing backslash", func() {
		drive := host.SystemDrive()

		Expect(drive).To(Equal("C:\\"))
	})
})
