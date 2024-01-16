// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package logging_test

import (
	"base/logging"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Base Logging Integration Tests", Label("integration"), Label("logging"))
}

var _ = Describe("RootLogDir", func() {
	It("return root log dir on Windows system drive", func() {
		dir := logging.RootLogDir()

		Expect(dir).To(Equal("C:\\var\\log"))
	})
})
