// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package systemrunning

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

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("image reset-win-storage", func() {
	It("prints system-running message and exits with non-zero", func(ctx context.Context) {
		if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("Linux-only")
		}

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("still running"))
	})

	It("prints not supported for linux-only", func(ctx context.Context) {
		if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
			Skip("not Linux-only")
		}

		output, _ := suite.K2sCli().ExpectedExitCode(-1).Exec(ctx, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("Resetting WinContainerStorage for Linux-only setup is not supported."))
	})
})
