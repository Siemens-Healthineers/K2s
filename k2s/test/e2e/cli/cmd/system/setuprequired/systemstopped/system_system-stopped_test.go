// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemstopped

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests", Label("cli", "system", "scp", "m", "w", "acceptance", "setup-required", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system", func() {
	DescribeTable("print system-not-running message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("not running"))
		},
		Entry("scp m", "system", "scp", "m", "a1", "a2"),
		Entry("scp w", "system", "scp", "w", "a1", "a2"),
		Entry("ssh m", "system", "ssh", "m", "--", "echo yes"),
		Entry("ssh w", "system", "ssh", "w", "--", "echo yes"),
	)

	DescribeTable("prints generic error and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("ERROR"))
		},
		Entry("ssh m", "system", "ssh", "m"),
		Entry("ssh w", "system", "ssh", "w"),
	)

	Describe("dump", func() {
		It("skips", func() {
			Skip("test to be implemented")
		})
	})
})
