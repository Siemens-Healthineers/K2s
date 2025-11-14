// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("proxy set", func() {
	Describe("proxySetCmd", func() {
		It("has correct command name", func() {
			Expect(proxySetCmd.Use).To(Equal("set"))
		})

		It("has short description", func() {
			Expect(proxySetCmd.Short).To(Equal("Set the proxy configuration"))
		})

		It("has long description", func() {
			Expect(proxySetCmd.Long).To(Equal("Set the proxy configuration for the application"))
		})

		It("has RunE function defined", func() {
			Expect(proxySetCmd.RunE).NotTo(BeNil())
		})

		It("has no subcommands", func() {
			Expect(proxySetCmd.Commands()).To(BeEmpty())
		})

		It("requires exactly one argument", func() {
			Expect(proxySetCmd.RunE).NotTo(BeNil())
		})

		It("accepts no flags", func() {
			Expect(proxySetCmd.Flags().HasFlags()).To(BeFalse())
		})
	})

	Describe("PowerShell script invocation", func() {
		It("uses correct script path", func() {
			expectedScript := utils.FormatScriptFilePath(path.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "proxy", "SetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring("SetProxy.ps1"))
			Expect(expectedScript).To(ContainSubstring(path.Join("lib", "scripts", "k2s", "system", "proxy")))
		})
	})

})
