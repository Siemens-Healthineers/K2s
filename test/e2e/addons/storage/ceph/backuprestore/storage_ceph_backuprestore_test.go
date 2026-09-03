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
	"github.com/siemens-healthineers/k2s/test/e2e/addons/exportimport"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 30

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestStorageCephBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "storage-ceph", "ceph", "backup-restore-ceph", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-storage-ceph")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
	os.RemoveAll(backupDir)
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("storage_ceph_backup_%s.zip", suffix))
}

var _ = Describe("'storage ceph' addon backup/restore", Ordered, func() {
	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		_ = os.RemoveAll(backupDir)
		_ = os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		k2s.VerifyAddonIsDisabled("storage", "ceph")
	})

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "storage", "ceph")
		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "storage", "ceph", "-f", fakePath)
		Expect(output).To(ContainSubstring("not found"))
	})

	It("enables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "storage", "ceph", "-f", zipPath, "-o")
		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "storage", "ceph", "-f", zipPath)
		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		k2s.VerifyAddonIsDisabled("storage", "ceph")
	})

	It("restores from backup successfully", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "storage", "ceph", "-f", zipPath, "-o")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
	})

	It("can be enabled when only addons/common and addons/storage are present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")

		restore, err := exportimport.StageAddonIsolation(suite.RootDir(), "storage")
		Expect(err).ToNot(HaveOccurred(), "staging addon isolation should succeed")
		DeferCleanup(func() {
			Expect(restore()).To(Succeed(), "addon isolation restore must succeed")
		})
		DeferCleanup(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "--force", "-o")
		})

		output := suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o")
		k2s.VerifyAddonIsEnabled("storage", "ceph")
		Expect(output).ToNot(ContainSubstring("no valid module file was found"))
		Expect(output).ToNot(ContainSubstring("was not loaded"))
	})
})
