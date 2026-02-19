// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package backuprestore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestDashboardBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dashboard Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "dashboard", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-dashboard")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if k2s.IsAddonEnabled("ingress", "nginx-gw") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
		k2s.VerifyAddonIsDisabled("ingress", "nginx-gw")
	}
	cleanupBackupDir()

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func cleanupBackupDir() {
	os.RemoveAll(backupDir)
}

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("dashboard_backup_%s.zip", suffix))
}

var _ = Describe("'dashboard' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "dashboard", "-o")
			k2s.VerifyAddonIsDisabled("dashboard")

		})

		// --- error tests while addon is disabled (no extra transitions) ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "dashboard")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "dashboard", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

			k2s.VerifyAddonIsEnabled("dashboard")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "dashboard", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "dashboard", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")

			k2s.VerifyAddonIsDisabled("dashboard")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kubernetes-dashboard-web", "dashboard")
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "dashboard", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("dashboard")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-api", "dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard-web", "dashboard")
		})
	})
})
