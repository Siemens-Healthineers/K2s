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

func TestRegistryBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "registry Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "registry", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-registry")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "registry", "-o")

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
	return filepath.Join(backupDir, fmt.Sprintf("registry_backup_%s.zip", suffix))
}

var _ = Describe("'registry' addon backup/restore", Ordered, func() {

	Describe("backup and restore", func() {
		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("basic")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "registry", "-o")
			k2s.VerifyAddonIsDisabled("registry")
		})

		// --- error tests while addon is disabled ---

		It("fails backup when addon is disabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "registry")

			Expect(output).To(ContainSubstring("not enabled"))
		})

		It("fails restore with a non-existent backup file", func(ctx context.Context) {
			fakePath := filepath.Join(backupDir, "does-not-exist.zip")

			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "registry", "-f", fakePath)

			Expect(output).To(ContainSubstring("not found"))
		})

		// --- enable → backup → error while enabled → disable → restore ---

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")

			k2s.VerifyAddonIsEnabled("registry")

			suite.Cluster().ExpectStatefulSetToBeReady("registry", "registry", 1, ctx)
		})

		It("creates a backup", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "registry", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("fails restore while addon is still enabled", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "registry", "-f", zipPath)

			Expect(output).To(ContainSubstring("disable"))
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")

			k2s.VerifyAddonIsDisabled("registry")

			suite.Cluster().ExpectStatefulSetToBeDeleted("registry", "registry", ctx)
		})

		It("restores from backup successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "registry", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("registry")

			suite.Cluster().ExpectStatefulSetToBeReady("registry", "registry", 1, ctx)
		})
	})

	Describe("backup and restore preserves registry-config ConfigMap data", func() {
		// Backup.ps1 captures the registry-config ConfigMap's .data field.
		// Restore.ps1 re-applies it with server-side apply after Enable.ps1
		// creates a fresh ConfigMap.  We add a custom data key before backup
		// and verify it survives the full cycle.
		const (
			testNamespace     = "registry"
			configMapName     = "registry-config"
			customDataKey     = "k2s-test-marker"
			customDataValue   = "backup-restore-sentinel"
		)

		var zipPath string

		BeforeAll(func() {
			zipPath = backupZipPath("with-data")
			cleanupBackupDir()
			os.MkdirAll(backupDir, os.ModePerm)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "registry", "-o")
			k2s.VerifyAddonIsDisabled("registry")
		})

		It("enables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")

			k2s.VerifyAddonIsEnabled("registry")

			suite.Cluster().ExpectStatefulSetToBeReady("registry", "registry", 1, ctx)
		})

		It("patches the ConfigMap with a custom data key", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "patch", "configmap", configMapName, "-n", testNamespace,
				"--type=merge", "-p", fmt.Sprintf(`{"data":{"%s":"%s"}}`, customDataKey, customDataValue))

			output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", testNamespace,
				"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
			Expect(output).To(Equal(customDataValue))
		})

		It("creates a backup containing the patched ConfigMap", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "backup", "registry", "-f", zipPath, "-o")

			Expect(zipPath).To(BeAnExistingFile())
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")

			k2s.VerifyAddonIsDisabled("registry")

			suite.Cluster().ExpectStatefulSetToBeDeleted("registry", "registry", ctx)
		})

		It("restores from backup and the custom data key is present", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "restore", "registry", "-f", zipPath, "-o")

			k2s.VerifyAddonIsEnabled("registry")

			suite.Cluster().ExpectStatefulSetToBeReady("registry", "registry", 1, ctx)

			// The backed-up ConfigMap contained our custom data key.
			// Restore.ps1 applies it with --server-side --force-conflicts,
			// overwriting the fresh ConfigMap from Enable.ps1.
			output := suite.Kubectl().MustExec(ctx, "get", "configmap", configMapName, "-n", testNamespace,
				"-o", fmt.Sprintf("jsonpath={.data['%s']}", customDataKey))
			Expect(output).To(Equal(customDataValue))
		})
	})
})
