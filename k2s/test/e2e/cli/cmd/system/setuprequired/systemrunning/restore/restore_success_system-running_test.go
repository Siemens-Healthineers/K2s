// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package systemrunning

import (
 "context"
 "fmt"
 "os"
 "path/filepath"
 "strconv"
 "testing"
 "time"

 "github.com/siemens-healthineers/k2s/test/framework"

 . "github.com/onsi/ginkgo/v2"
 . "github.com/onsi/gomega"
)

const (
 successMessage = "System restore completed"
)

var (
 restoreSuite      *framework.K2sTestSuite
 restoreRandomSeed string
 validBackupFile   string
)

func TestRestoreSuccessSystemRunning(t *testing.T) {
 RegisterFailHandler(Fail)
 RunSpecs(t, "System Restore Success Tests", Label("e2e", "system", "restore", "success", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
 restoreSuite = framework.Setup(ctx,
  framework.SystemMustBeRunning,
  framework.ClusterTestStepPollInterval(time.Millisecond*200),
  framework.ClusterTestStepTimeout(time.Minute*5))

 restoreRandomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)

 validBackupFile = createValidBackupForRestore(ctx)

 DeferCleanup(func(ctx context.Context) {
  cleanupBackupFile(ctx, validBackupFile)
 })
})

var _ = AfterSuite(func(ctx context.Context) {
 restoreSuite.TearDown(ctx)
})

var _ = Describe("k2s system restore - success path", Ordered, func() {
 It("restores system successfully from valid backup", func(ctx context.Context) {
  GinkgoWriter.Println("Restoring system from:", validBackupFile)

  output := restoreSuite.K2sCli().MustExec(ctx, "system", "restore", "-f", validBackupFile)

  Expect(output).To(ContainSubstring(successMessage), "Should complete restore successfully")
 })

 It("backup file remains intact after restore", func(ctx context.Context) {
  Expect(validBackupFile).To(BeAnExistingFile(), "Backup file should still exist after restore")
 })
})

func createValidBackupForRestore(ctx context.Context) string {
 backupDir := GinkgoT().TempDir()
 backupFile := filepath.Join(backupDir, fmt.Sprintf("valid-backup-%s.zip", restoreRandomSeed))

 GinkgoWriter.Println("Creating valid backup for restore tests:", backupFile)
 restoreSuite.K2sCli().MustExec(ctx, "system", "backup", "-f", backupFile)

 Expect(backupFile).To(BeAnExistingFile(), "Created backup should exist")

 return backupFile
}

func cleanupBackupFile(ctx context.Context, backupFile string) {
 if backupFile == "" {
  return
 }

 GinkgoWriter.Println("Cleaning up backup file:", backupFile)

 err := os.Remove(backupFile)
 if err != nil && !os.IsNotExist(err) {
  GinkgoWriter.Printf("Warning: Failed to cleanup backup file %s: %v\n", backupFile, err)
 }
}
