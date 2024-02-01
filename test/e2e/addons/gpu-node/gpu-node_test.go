// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package gpunode

import (
	"context"
	"k2sTest/framework"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite

func TestAddon(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "gpu-node Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "gpu-node", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'gpu-node' addon", Ordered, func() {
	When("addon is disabled", func() {
		Describe("disable", func() {
			var output string

			BeforeAll(func(ctx context.Context) {
				output = suite.K2sCli().Run(ctx, "addons", "disable", "gpu-node")
			})

			It("prints already-disabled message", func() {
				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})
})
