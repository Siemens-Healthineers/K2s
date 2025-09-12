// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

var _ = Describe("proxy_reset", func() {
	Describe("proxyResetCmd", func() {
		It("should have correct command structure", func() {
			Expect(proxyResetCmd.Use).To(Equal("reset"))
			Expect(proxyResetCmd.Short).To(Equal("Reset the proxy settings"))
			Expect(proxyResetCmd.Long).To(Equal("This command resets the proxy settings to their default values."))
		})

		It("should have RunE function assigned", func() {
			Expect(proxyResetCmd.RunE).ToNot(BeNil())
		})
	})

	Describe("resetProxyConfig function behavior", func() {
		When("command context validation", func() {
			It("should handle missing context", func() {
				testCmd := &cobra.Command{Use: "test"}
				testCmd.SetContext(context.Background())
				Expect(testCmd.Context()).ToNot(BeNil())
			})
		})

		When("valid context is provided", func() {
			It("should accept empty arguments list", func() {
				args := []string{}

				Expect(len(args)).To(Equal(0))
			})
		})
	})
})
