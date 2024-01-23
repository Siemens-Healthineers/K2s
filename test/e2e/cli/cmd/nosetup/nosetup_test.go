// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
)

var suite *framework.K2sTestSuite

func TestCmd(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("commands", func() {
	DescribeTable("print not-installed message",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().Run(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("start", "start"),
		Entry("stop", "stop"),
		Entry("uninstall", "uninstall"),
		Entry("upgrade", "upgrade"),
	)
})
