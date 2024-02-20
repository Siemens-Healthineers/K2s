// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package install

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

func TestInstall(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "install CLI Command Acceptance Tests", Label("cli", "install", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("install commands", func() {
	DescribeTable("print already-installed message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("setup already installed"))
		},
		Entry(nil, "install"),
		Entry(nil, "install", "--linux-only"),
		Entry(nil, "install", "multivm"),
		Entry(nil, "install", "buildonly"),
	)
})
