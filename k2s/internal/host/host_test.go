// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
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
	RunSpecs(t, "host pkg Unit Tests", Label("ci", "internal", "host"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("host pkg", Ordered, func() {
	Describe("SystemDrive", Label("unit"), func() {
		It("returns Windows system drive with trailing backslash", func() {
			drive := host.SystemDrive()

			Expect(drive).To(Equal("C:\\"))
		})
	})

	Describe("ReplaceTildeWithHomeDir", Label("integration"), func() {
		When("path contains tilde", func() {
			It("replaces tilde with user's home directory", func() {
				const input = "~\\dir\\file.md"

				actual, err := host.ReplaceTildeWithHomeDir(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(MatchRegexp(`^C:\\Users\\[^\\]+\\dir\\file\.md$`))
			})
		})

		When("path does not contain tilde", func() {
			It("returns same path", func() {
				const input = "c:\\dir\\file.md"

				actual, err := host.ReplaceTildeWithHomeDir(input)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(input))
			})
		})
	})
})
