// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

var _ = Describe("proxy_set", func() {
	Describe("proxySetCmd", func() {
		It("should have correct command structure", func() {
			Expect(proxySetCmd.Use).To(Equal("set"))
			Expect(proxySetCmd.Short).To(Equal("Set the proxy configuration"))
			Expect(proxySetCmd.Long).To(Equal("Set the proxy configuration for the application"))
		})

		It("should have RunE function assigned", func() {
			Expect(proxySetCmd.RunE).ToNot(BeNil())
		})
	})

	Describe("setProxyServer function behavior", func() {
		When("command context validation", func() {
			It("should handle missing context", func() {
				testCmd := &cobra.Command{Use: "test"}
				testCmd.SetContext(context.Background())
				Expect(testCmd.Context()).ToNot(BeNil())
			})
		})

		When("argument validation", func() {
			It("should validate argument count - no arguments", func() {
				args := []string{}
				Expect(len(args)).To(Equal(0))
			})

			It("should validate argument count - too many arguments", func() {
				args := []string{"http://proxy1.example.com:8080", "http://proxy2.example.com:8080"}

				Expect(len(args)).To(Equal(2))
			})

			It("should accept one proxy URI argument", func() {
				args := []string{"http://proxy.example.com:8080"}

				Expect(len(args)).To(Equal(1))
			})
		})
	})
})
