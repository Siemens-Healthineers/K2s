// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package systemrunning

import (
 "archive/zip"
 "context"
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
 backupFileName = "k2s-backup.zip"
 backupJsonFile = "backup.json"
)

var (
 suite          *framework.K2sTestSuite
 randomSeed     string
 testBackupDir  string
 testBackupFile string
)

func TestBackupSystemRunning(t *testing.T) {
 RegisterFailHandler(Fail)
 RunSpecs(t, "System Backup Acceptance Tests", Label("e2e", "system", "backup", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
 suite = framework.Setup(ctx,
  framework.SystemMustBeRunning,
  framework.ClusterTestStepPollInterval(time.Millisecond*200),
  framework.ClusterTestStepTimeout(time.Minute*5))

 randomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)
 testBackupDir = GinkgoT().TempDir()
})

var _ = AfterSuite(func(ctx context.Context) {
 suite.TearDown(ctx)
})

var _ = Describe("k2s system backup", Ordered, func() {
 BeforeAll(func() {
  testBackupFile = filepath.Join(testBackupDir, backupFileName)

  DeferCleanup(func(ctx context.Context) {
   cleanupBackupFile(ctx, testBackupFile)
  })
 })

 It("creates backup successfully", func(ctx context.Context) {
  GinkgoWriter.Println("Creating system backup at:", testBackupFile)

  suite.K2sCli().MustExec(ctx, "system", "backup", "-f", testBackupFile)

  Expect(testBackupFile).To(BeAnExistingFile(), "Backup file should exist")
 })

 It("verifies backup contains backup.json", func(ctx context.Context) {
  zipReader, err := zip.OpenReader(testBackupFile)
  Expect(err).NotTo(HaveOccurred(), "Should open backup archive")
  defer zipReader.Close()

  foundBackupJson := false
  for _, file := range zipReader.File {
   if file.Name == backupJsonFile {
    foundBackupJson = true
    break
   }
  }

  Expect(foundBackupJson).To(BeTrue(), "backup.json should exist in archive")
 })
})

func cleanupBackupFile(ctx context.Context, backupFile string) {
 if _, err := os.Stat(backupFile); err == nil {
  os.Remove(backupFile)
  GinkgoWriter.Printf("Cleaned up backup file: %s\n", backupFile)
 }
}
