// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package compact

import (
	"context"
	"os"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestCompactSystemRunning(t *testing.T) {
	os.Setenv("SYSTEM_TEST_TIMEOUT", "30m")
	RegisterFailHandler(Fail)
	RunSpecs(t, "system compact Acceptance Tests (system running)",
		Label("cli", "system", "compact", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(30*time.Minute),
	)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system compact", Ordered, func() {

	Describe("when system is running", Ordered, func() {

		It("runs fstrim, stops cluster, compacts VHDX and restarts cluster", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes")

			Expect(output).To(SatisfyAll(
				ContainSubstring("fstrim"),
				ContainSubstring("Stopping cluster"),
				ContainSubstring("Cluster stopped successfully"),
				ContainSubstring("Optimizing VHDX"),
				ContainSubstring("Optimization completed"),
				ContainSubstring("Restarting cluster"),
				ContainSubstring("Cluster restarted successfully"),
				ContainSubstring("VHDX compaction completed successfully"),
			))
		})

		It("reports before/after size and space saved", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "compact", "--yes")

			Expect(output).To(SatisfyAll(
				ContainSubstring("Before:"),
				ContainSubstring("After:"),
				ContainSubstring("Saved:"),
				ContainSubstring("Compaction Results"),
			))
		})
	})

	Describe("when system is running and --no-restart is specified", Ordered, func() {
		var noRestartOutput string

		BeforeAll(func(ctx context.Context) {
			if !suite.StatusChecker().IsK2sRunning(ctx) {
				GinkgoWriter.Println("Cluster not running before --no-restart test; starting...")
				suite.K2sCli().MustExec(ctx, "start")
			}

			noRestartOutput = suite.K2sCli().MustExec(ctx, "system", "compact", "--yes", "--no-restart")
		})

		AfterAll(func(ctx context.Context) {
			GinkgoWriter.Println("Restarting cluster after --no-restart compact test...")
			suite.K2sCli().MustExec(ctx, "start")
		})

		It("stops cluster, compacts VHDX and leaves cluster stopped", func() {
			Expect(noRestartOutput).To(SatisfyAll(
				ContainSubstring("fstrim"),
				ContainSubstring("Stopping cluster"),
				ContainSubstring("Cluster stopped successfully"),
				ContainSubstring("Optimizing VHDX"),
				ContainSubstring("Optimization completed"),
				ContainSubstring("VHDX compaction completed successfully"),
			))
		})

		It("does NOT restart the cluster when --no-restart is specified", func() {
			Expect(noRestartOutput).To(ContainSubstring("no-restart"))
			Expect(noRestartOutput).NotTo(ContainSubstring("Restarting cluster"))
			Expect(noRestartOutput).NotTo(ContainSubstring("Cluster restarted successfully"))
		})

		It("leaves the cluster in a stopped state after compaction", func(ctx context.Context) {
			Expect(suite.StatusChecker().IsK2sRunning(ctx)).To(BeFalse(),
				"cluster should be stopped after compact --no-restart")
		})
	})
})

