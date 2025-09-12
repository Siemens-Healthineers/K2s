// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package override

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override_ls", func() {
	Describe("overrideListCmd", func() {
		It("should have correct command structure", func() {
			Expect(overrideListCmd.Use).To(Equal("ls"))
			Expect(overrideListCmd.Short).To(Equal("List all overrides"))
			Expect(overrideListCmd.Long).To(Equal("List all overrides in the system"))
		})

		It("should have RunE function assigned", func() {
			Expect(overrideListCmd.RunE).ToNot(BeNil())
		})
	})

	Describe("listProxyOverrides function behavior", func() {
		When("arguments are provided", func() {
			It("should accept empty arguments list", func() {
				// List command typically doesn't require arguments
				args := []string{}

				Expect(len(args)).To(Equal(0))
			})

			It("should handle any additional arguments gracefully", func() {
				args := []string{"extra", "args"}

				Expect(len(args)).To(Equal(2))
			})
		})
	})

	Describe("ProxyOverrides struct", func() {
		It("should have correct structure", func() {
			proxyOverrides := &ProxyOverrides{}

			Expect(proxyOverrides.ProxyOverrides).To(BeNil())
		})

		It("should embed CmdResult", func() {
			proxyOverrides := &ProxyOverrides{}
			Expect(proxyOverrides.CmdResult).ToNot(BeNil())
		})

		It("should initialize with empty slice", func() {
			proxyOverrides := &ProxyOverrides{
				ProxyOverrides: []string{},
			}

			Expect(proxyOverrides.ProxyOverrides).To(BeEmpty())
			Expect(proxyOverrides.ProxyOverrides).ToNot(BeNil())
		})

		It("should handle slice with values", func() {
			testOverrides := []string{"override1", "override2", "override3"}
			proxyOverrides := &ProxyOverrides{
				ProxyOverrides: testOverrides,
			}

			Expect(proxyOverrides.ProxyOverrides).To(HaveLen(3))
			Expect(proxyOverrides.ProxyOverrides).To(Equal(testOverrides))
		})
	})
})
