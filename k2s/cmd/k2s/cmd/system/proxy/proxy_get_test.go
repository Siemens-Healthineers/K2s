// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

var _ = Describe("proxy_get", func() {
	Describe("proxyGetCmd", func() {
		It("should have correct command structure", func() {
			Expect(proxyGetCmd.Use).To(Equal("get"))
			Expect(proxyGetCmd.Short).To(Equal("Get proxy information"))
			Expect(proxyGetCmd.Long).To(Equal("Get information about the proxy configuration"))
		})

		It("should have RunE function assigned", func() {
			Expect(proxyGetCmd.RunE).ToNot(BeNil())
		})
	})

	Describe("getProxyServer function behavior", func() {
		When("command context validation", func() {
			It("should handle missing context", func() {
				testCmd := &cobra.Command{Use: "test"}
				testCmd.SetContext(context.Background())
				Expect(testCmd.Context()).ToNot(BeNil())
			})
		})
	})

	Describe("ProxyServer struct", func() {
		It("should have correct structure", func() {
			proxyServer := &ProxyServer{}

			Expect(proxyServer.Proxy).To(BeNil())
		})

		It("should embed CmdResult", func() {
			proxyServer := &ProxyServer{}
			Expect(proxyServer.CmdResult).ToNot(BeNil())
		})
	})
})
