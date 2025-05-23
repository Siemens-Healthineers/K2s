// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node CLI Commands Acceptance Tests", Label("cli", "ci", "node", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node", func() {
	Describe("copy", Label("copy"), func() {
		It("prints system-not-installed message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "copy", "--ip-addr", "", "-s", "", "-t", "", "-u", "")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Describe("exec", Label("exec"), func() {
		It("prints system-not-installed message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "exec", "-i", "", "-u", "", "-c", "")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Describe("connect", Label("connect"), func() {
		It("prints system-not-installed message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "connect", "-i", "", "-u", "")

			Expect(output).To(ContainSubstring("not installed"))
		})
	})
})
