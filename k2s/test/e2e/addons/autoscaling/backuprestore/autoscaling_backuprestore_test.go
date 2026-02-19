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

func TestAutoscalingBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "autoscaling Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "autoscaling", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-autoscaling")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "autoscaling", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("autoscaling_backup_%s.zip", suffix))
}

var _ = Describe("'autoscaling' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "autoscaling", "-o")
			k2s.VerifyAddonIsDisabled("autoscaling")
		})

		// --- error tests while addon is disabled (no extra transitions) ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "autoscaling")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "autoscaling", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")

			k2s.VerifyAddonIsEnabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "autoscaling", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "autoscaling", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")

			k2s.VerifyAddonIsDisabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "keda-admission", "autoscaling")
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "autoscaling", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
		})
	})

	Describe("backup and restore with custom state", func() {
		const (
			testConfigMapName = "k2s-backup-test-cm"
			testNamespace     = "autoscaling"
		)

		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("with-cm")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "autoscaling", "-o")
			k2s.VerifyAddonIsDisabled("autoscaling")
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")

			k2s.VerifyAddonIsEnabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
		})

		It("creates a test ConfigMap in the addon namespace", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "create", "configmap", testConfigMapName, "--from-literal=test-key=test-value", "-n", testNamespace)

			output := suite.Kubectl().MustExec(ctx, "get", "configmap", testConfigMapName, "-n", testNamespace)
			Expect(output).To(ContainSubstring(testConfigMapName))
		})

		It("creates a backup containing the ConfigMap", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "autoscaling", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")

			k2s.VerifyAddonIsDisabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "keda-admission", "autoscaling")
		})

		It("restores from backup and the ConfigMap is present", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "autoscaling", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("autoscaling")

			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")

			output := suite.Kubectl().MustExec(ctx, "get", "configmap", testConfigMapName, "-n", testNamespace, "-o", "jsonpath={.data.test-key}")
			Expect(output).To(Equal("test-value"))
		})
	})
})
