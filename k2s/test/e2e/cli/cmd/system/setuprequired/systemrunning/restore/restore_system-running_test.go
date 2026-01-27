// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package restore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	successMessage       = "System restore completed"
	testClusterTimeout   = time.Minute * 5
)

var (
	suite          *framework.K2sTestSuite
	randomSeed     string
	validBackupFile string
	testTempDir    string
)

func TestRestoreSystemRunning(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "System Restore Acceptance Tests", Label("e2e", "system", "restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(time.Millisecond*200),
		framework.ClusterTestStepTimeout(testClusterTimeout))

	randomSeed = strconv.FormatInt(GinkgoRandomSeed(), 10)

	// Create test temp directory
	var err error
	testTempDir, err = os.MkdirTemp("", "k2s-restore-test-*")
	Expect(err).ToNot(HaveOccurred())

	// Create valid backup file
	validBackupFile = createValidBackupForRestore(ctx)

	DeferCleanup(func(ctx context.Context) {
		cleanupBackupFile(ctx, validBackupFile)
	})
})

var _ = AfterSuite(func(ctx context.Context) {
	if testTempDir != "" {
		os.RemoveAll(testTempDir)
	}
	suite.TearDown(ctx)
})

var _ = Describe("'k2s system restore'", Ordered, func() {
	Describe("success scenarios", func() {
		Context("with valid backup file", func() {
			It("restores system successfully from valid backup", func(ctx context.Context) {
				GinkgoWriter.Println("Restoring system from:", validBackupFile)

				output := suite.K2sCli().MustExec(ctx, "system", "restore", "-f", validBackupFile)

				Expect(output).To(ContainSubstring(successMessage), "Should complete restore successfully")
			})

			It("backup file remains intact after restore", func(ctx context.Context) {
				Expect(validBackupFile).To(BeAnExistingFile(), "Backup file should still exist after restore")
			})
		})
	})

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
			It("successfully restores the system with error flag enabled", func(ctx context.Context) {
				output, exitCode := suite.K2sCli().Exec(ctx,
					"system", "restore",
					"-f", validBackupFile,
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
			It("successfully restores the system without error flag", func(ctx context.Context) {
				output, exitCode := suite.K2sCli().Exec(ctx,
					"system", "restore",
					"-f", validBackupFile)

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

func createValidBackupForRestore(ctx context.Context) string {
	backupFile := filepath.Join(testTempDir, fmt.Sprintf("valid-backup-%s.zip", randomSeed))

	GinkgoWriter.Println("Creating valid backup for restore tests:", backupFile)

	// Run backup command (creates file in default location)
	output, exitCode := suite.K2sCli().Exec(ctx, "system", "backup")
	Expect(exitCode).To(Equal(0), "Failed to create test backup: %s", output)

	// Extract the actual backup file path from output
	backupPath := extractBackupPath(output)
	Expect(backupPath).NotTo(BeEmpty(), "Could not find backup file path in output: %s", output)
	Expect(backupPath).To(BeAnExistingFile(), "Backup file does not exist at reported path: %s", backupPath)

	// Copy to our test directory for isolation
	data, err := os.ReadFile(backupPath)
	Expect(err).ToNot(HaveOccurred(), "Failed to read backup file from %s", backupPath)

	err = os.WriteFile(backupFile, data, 0644)
	Expect(err).ToNot(HaveOccurred(), "Failed to write backup file to %s", backupFile)

	// Clean up original backup
	os.Remove(backupPath)

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

func extractBackupPath(output string) string {
 lines := strings.Split(output, "\n")
 for _, line := range lines {
  line = strings.TrimSpace(line)

  // Look for "Backup file created at:" pattern
  idx := strings.Index(line, "Backup file created at:")
  if idx >= 0 {
   pathPart := strings.TrimSpace(line[idx+len("Backup file created at:"):])
   if len(pathPart) > 2 && pathPart[1] == ':' {
    return pathPart
   }
  }

  // Fallback: look for any line ending with .zip that looks like an absolute path
  if strings.HasSuffix(strings.ToLower(line), ".zip") {
   if strings.Contains(line, "]") {
    parts := strings.Split(line, "]")
    if len(parts) > 1 {
     lastPart := strings.TrimSpace(parts[len(parts)-1])
     if len(lastPart) > 2 && lastPart[1] == ':' && filepath.IsAbs(lastPart) {
      return lastPart
     }
    }
   }
   if len(line) > 2 && line[1] == ':' && filepath.IsAbs(line) {
    return line
   }
  }
 }
 return ""
}