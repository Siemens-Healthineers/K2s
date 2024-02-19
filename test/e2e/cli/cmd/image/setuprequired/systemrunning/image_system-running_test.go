// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemrunning

import (
	"context"
	"k2s/setupinfo"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
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
	It("prints system-running message", func(ctx context.Context) {
		if suite.SetupInfo().LinuxOnly {
			Skip("Linux-only")
		}

		if suite.SetupInfo().Name == setupinfo.SetupNameMultiVMK8s {
			Skip("Multi-vm")
		}

		output := suite.K2sCli().Run(ctx, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("still running"))
	})

	It("prints reinstall cluster message", func(ctx context.Context) {
		if suite.SetupInfo().Name == setupinfo.SetupNamek2s {
			Skip("k2s setup")
		}

		output := suite.K2sCli().Run(ctx, "image", "reset-win-storage")

		Expect(output).To(ContainSubstring("In order to clean up WinContainerStorage for multi-vm, please reinstall the cluster!"))
	})
})
