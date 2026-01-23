// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package restore

import (
 "context"
 "os"
 "path/filepath"
 "strings"
 "testing"
 "time"

 "github.com/siemens-healthineers/k2s/internal/cli"
 "github.com/siemens-healthineers/k2s/test/framework"

 . "github.com/onsi/ginkgo/v2"
 . "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 5

var (
 suite          *framework.K2sTestSuite
 testBackupFile string
 testTempDir    string
)

func TestSystemRestore(t *testing.T) {
 RegisterFailHandler(Fail)
 RunSpecs(t, "system restore Command Acceptance Tests", Label("cli", "system", "restore", "acceptance", "setup-required", "invasive", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
 suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepTimeout(testClusterTimeout))

 // Create test backup directory
 var err error
 testTempDir, err = os.MkdirTemp("", "k2s-restore-test-*")
 Expect(err).ToNot(HaveOccurred())

 // Run backup command (creates file in C:\ProgramData\k2s\backups\)
 output, exitCode := suite.K2sCli().Exec(ctx, "system", "backup")
 Expect(exitCode).To(Equal(0), "Failed to create test backup: %s", output)

 // Extract the actual backup file path from output
 backupPath := extractBackupPath(output)
 Expect(backupPath).NotTo(BeEmpty(), "Could not find backup file path in output: %s", output)
 Expect(backupPath).To(BeAnExistingFile(), "Backup file does not exist at reported path: %s", backupPath)

 // Copy the backup file to our test directory for cleanup and isolation
 testBackupFile = filepath.Join(testTempDir, "test-backup.zip")
 data, err := os.ReadFile(backupPath)
 Expect(err).ToNot(HaveOccurred(), "Failed to read backup file from %s", backupPath)

 err = os.WriteFile(testBackupFile, data, 0644)
 Expect(err).ToNot(HaveOccurred(), "Failed to write backup file to %s", testBackupFile)

 // Clean up the original backup file to avoid cluttering system
 os.Remove(backupPath)

 Expect(testBackupFile).To(BeAnExistingFile())
 GinkgoWriter.Printf("Test backup file created at: %s\n", testBackupFile)
})

var _ = AfterSuite(func(ctx context.Context) {
 // Clean up test backup directory
 if testTempDir != "" {
  os.RemoveAll(testTempDir)
 }

 suite.TearDown(ctx)
})

var _ = Describe("'k2s system restore'", Ordered, func() {
 Describe("with --error-on-failure flag", func() {
  Context("when backup file does not exist", func() {
   It("exits with failure code", func(ctx context.Context) {
    nonExistentFile := filepath.Join(testTempDir, "non-existent-backup.zip")

    output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx,
     "system", "restore",
     "-f", nonExistentFile,
     "-e")

    Expect(output).To(Or(
     ContainSubstring("Backup file not found"),
     ContainSubstring("not found"),
    ))
   })
  })

  Context("when backup file is invalid or corrupted", func() {
   var corruptedFile string

   BeforeAll(func() {
    corruptedFile = filepath.Join(testTempDir, "corrupted-backup.zip")
    err := os.WriteFile(corruptedFile, []byte("invalid zip content"), 0644)
    Expect(err).ToNot(HaveOccurred())
   })

   It("exits with failure code when restoration fails", func(ctx context.Context) {
    output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx,
     "system", "restore",
     "-f", corruptedFile,
     "-e")

    Expect(output).To(Or(
     ContainSubstring("failed"),
     ContainSubstring("error"),
     ContainSubstring("invalid"),
     ContainSubstring("corrupted"),
    ))
   })
  })

  Context("with valid backup file", func() {
   It("successfully restores the system", func(ctx context.Context) {
    output, exitCode := suite.K2sCli().Exec(ctx,
     "system", "restore",
     "-f", testBackupFile,
     "-e")

    Expect(exitCode).To(Equal(0))
    Expect(output).To(Or(
     ContainSubstring("successfully"),
     ContainSubstring("completed"),
     ContainSubstring("restored"),
    ))
   })
  })
 })

 Describe("without --error-on-failure flag (default behavior)", func() {
  Context("when backup file does not exist", func() {
   It("still fails because file validation happens before error flag logic", func(ctx context.Context) {
    nonExistentFile := filepath.Join(testTempDir, "another-non-existent.zip")

    output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx,
     "system", "restore",
     "-f", nonExistentFile)

    Expect(output).To(Or(
     ContainSubstring("Backup file not found"),
     ContainSubstring("not found"),
    ))
   })
  })

  Context("with valid backup file", func() {
   It("successfully restores the system", func(ctx context.Context) {
    output, exitCode := suite.K2sCli().Exec(ctx,
     "system", "restore",
     "-f", testBackupFile)

    Expect(exitCode).To(Equal(0))
    Expect(output).To(Or(
     ContainSubstring("successfully"),
     ContainSubstring("completed"),
     ContainSubstring("restored"),
    ))
   })
  })
 })

 Describe("flag combinations", func() {
  Context("with --error-on-failure flag", func() {
   It("successfully restores with error flag", func(ctx context.Context) {
    output, exitCode := suite.K2sCli().Exec(ctx,
     "system", "restore",
     "-f", testBackupFile,
     "-e")

    Expect(exitCode).To(Equal(0))
    Expect(output).To(Or(
     ContainSubstring("successfully"),
     ContainSubstring("completed"),
     ContainSubstring("restored"),
    ))
   })
  })
 })
})

func extractBackupPath(output string) string {
 // The backup command outputs:
 // "⏳ [19:16:30] Backup file created at: C:\ProgramData\k2s\backups\k2s-backup-file-2026-01-23_19-15-22.zip"
 lines := strings.Split(output, "\n")
 for _, line := range lines {
  line = strings.TrimSpace(line)

  // Look for "Backup file created at:" pattern
  idx := strings.Index(line, "Backup file created at:")
  if idx >= 0 {
   // Extract everything after "Backup file created at:"
   pathPart := strings.TrimSpace(line[idx+len("Backup file created at:"):])
   // The path should be an absolute Windows path starting with drive letter
   if len(pathPart) > 2 && pathPart[1] == ':' {
    return pathPart
   }
  }

  // Fallback: look for any line ending with .zip that looks like an absolute path
  if strings.HasSuffix(strings.ToLower(line), ".zip") {
   // Extract just the path part if there's a timestamp prefix
   // Pattern: "[HH:MM:SS] ... path"
   if strings.Contains(line, "]") {
    parts := strings.Split(line, "]")
    if len(parts) > 1 {
     lastPart := strings.TrimSpace(parts[len(parts)-1])
     if len(lastPart) > 2 && lastPart[1] == ':' && filepath.IsAbs(lastPart) {
      return lastPart
     }
    }
   }
   // Direct absolute path check
   if len(line) > 2 && line[1] == ':' && filepath.IsAbs(line) {
    return line
   }
  }
 }
 return ""
}