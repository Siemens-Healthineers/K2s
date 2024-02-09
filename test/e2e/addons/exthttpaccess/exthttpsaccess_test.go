// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package exthttpaccess

import (
	"context"
	"encoding/json"
	"k2s/addons/status"
	"k2sTest/framework"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "exthttpaccess Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "exthttpaccess", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'exthttpaccess' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "status", "exthttpaccess", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		if *status.Enabled {
			GinkgoWriter.Println("exthttpaccess seems not to be disabled, disabling now..")

			suite.K2sCli().Run(ctx, "addons", "disable", "exthttpaccess")
		}
	})

	When("addon is disabled", func() {
		Describe("disable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "addons", "disable", "exthttpaccess")
			})

			It("prints already-disabled message", func() {
				Expect(output).To(ContainSubstring("already disabled"))
			})
		})

		Describe("enable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				args := []string{"addons", "enable", "exthttpaccess", "-f"}
				if suite.Proxy() != "" {
					args = append(args, "-p", suite.Proxy())
				}
				output = suite.K2sCli().Run(ctx, args...)
			})

			It("enables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess enabled"))
			})
		})
	})

	When("addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "addons", "status", "exthttpaccess", "-o", "json")

			var status status.AddonPrintStatus

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
			Expect(*status.Enabled).To(BeTrue())
		})

		Describe("enable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "addons", "enable", "exthttpaccess")
			})

			It("prints already-enabled message", func() {
				Expect(output).To(ContainSubstring("already enabled"))
			})
		})

		Describe("disable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "addons", "disable", "exthttpaccess")
			})

			It("disables the addon", func() {
				Expect(output).To(ContainSubstring("exthttpaccess disabled"))
			})
		})
	})
})
