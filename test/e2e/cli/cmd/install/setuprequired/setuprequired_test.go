// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package setuprequired

import (
	"context"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
)

var suite *framework.K2sTestSuite

func TestInstall(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install CLI Command Acceptance Tests", Label("cli", "install", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SkipClusterRunningCheck)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("install commands", Ordered, func() {
	DescribeTable("print already-installed message",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().Run(ctx, args...)

			Expect(output).To(ContainSubstring("setup already installed"))
		},
		Entry("install", "install"),
		Entry("install Linux-only", "install", "--linux-only"),
		Entry("install multi-VM", "install", "multivm"),
		Entry("install build-only", "install", "buildonly"),
	)
})
