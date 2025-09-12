// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/proxy/override"
	"github.com/spf13/cobra"
)

var _ = Describe("proxy", func() {
	Describe("ProxyCmd", func() {
		It("should have correct command structure", func() {
			Expect(ProxyCmd.Use).To(Equal("proxy"))
			Expect(ProxyCmd.Short).To(Equal("Manage proxy settings"))
		})

		It("should contain all expected subcommands", func() {
			commandNames := make([]string, 0)
			for _, cmd := range ProxyCmd.Commands() {
				commandNames = append(commandNames, cmd.Use)
			}

			Expect(commandNames).To(ContainElements("set", "get", "show", "reset", "override"))
		})

		It("should have the override subcommand", func() {
			var overrideCmd *cobra.Command
			for _, cmd := range ProxyCmd.Commands() {
				if cmd.Use == "override" {
					overrideCmd = cmd
					break
				}
			}

			Expect(overrideCmd).ToNot(BeNil())
			Expect(overrideCmd).To(Equal(override.OverrideCmd))
		})
	})
})
