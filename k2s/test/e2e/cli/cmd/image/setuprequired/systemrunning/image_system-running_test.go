// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemrunning

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
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
		if suite.SetupInfo().SetupConfig.LinuxOnly {
			Skip("Linux-only")
		}

		if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNameMultiVMK8s {
			Skip("Multi-vm")
		}

		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("still running"))
	})

	It("prints reinstall cluster message", func(ctx context.Context) {
		if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNamek2s {
			Skip("k2s setup")
		}

		if suite.SetupInfo().SetupConfig.LinuxOnly {
			Skip("Linux-only")
		}

		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("In order to clean up WinContainerStorage for multi-vm, please reinstall multi-vm cluster!"))
	})

	It("prints not supported for linux-only", func(ctx context.Context) {
		if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNamek2s {
			Skip("k2s setup")
		}

		if suite.SetupInfo().SetupConfig.SetupName == setupinfo.SetupNameMultiVMK8s && !suite.SetupInfo().SetupConfig.LinuxOnly {
			Skip("Multi-vm")
		}

		output := suite.K2sCli().RunWithExitCode(ctx, -1, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("Resetting WinContainerStorage for linux-only setup is not supported!"))
	})
})
