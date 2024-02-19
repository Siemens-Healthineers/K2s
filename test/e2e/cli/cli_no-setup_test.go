// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cli

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "CLI Acceptance Tests", Label("cli", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("CLI", func() {
	Describe("exit behavior", Ordered, func() {
		When("error happened while CLI executions", func() {
			It("prints the error and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "invalid", "command")

				Expect(output).To(SatisfyAll(
					ContainSubstring("ERROR"),
					ContainSubstring(`unknown command "invalid"`),
				))
			})
		})

		When("CLI execution successful", func() {
			It("prints no error", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeSuccess, "addons", "ls")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("Available Addons"))
			})
		})

		When("non-leaf command is issued", func() {
			It("prints help without errors", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeSuccess, "addons")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("Addons add optional functionality"))
			})
		})

		When("help flag is used", func() {
			It("prints help without errors", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeSuccess, "addons", "ls", "-h")

				Expect(output).ToNot(ContainSubstring("ERROR"))
				Expect(output).To(ContainSubstring("List addons available"))
			})
		})
	})

	Describe("commands that do not have dedicated e2e tests yet", func() {
		DescribeTable("prints system-not-installed message and exits with non-zero",
			func(ctx context.Context, args ...string) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

				Expect(output).To(ContainSubstring("not installed"))
			},
			Entry("start", "start"),
			Entry("stop", "stop"),
			Entry("uninstall", "uninstall"),
			Entry("upgrade", "upgrade"),
		)
	})
})
