// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/host"
)

func TestHostPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "host pkg Unit Tests", Label("unit", "ci", "internal", "host"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("host pkg", Ordered, func() {
	Describe("SystemDrive", func() {
		It("returns Windows system drive with trailing backslash", func() {
			drive := host.SystemDrive()

			Expect(drive).To(Equal("C:\\"))
		})
	})
})
