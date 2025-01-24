// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package scp

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
)

var suite *framework.K2sTestSuite

func TestScp(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system scp CLI Commands Acceptance Tests", Label("cli", "system", "scp", "m", "w", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system scp", func() {
	Describe("m", func() {
		Context("source file not existing", func() {
			It("returns a warning after failure", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "system", "scp", "m", "non-existing.file", "/tmp")

				Expect(output).To(SatisfyAll(
					MatchRegexp("WARNING"),
					MatchRegexp("Could not copy"),
					MatchRegexp("No such file"),
				))
			})
		})

		Context("source file and target dir exist", func() {
			const testFileName = "system_scp_m_test.txt"
			const tempFileContent = "scp-m-test\n"
			var localTempFilePath string
			var remoteTempFilePath string

			BeforeEach(func() {
				tempDir := GinkgoT().TempDir()
				localTempFilePath = filepath.Join(tempDir, testFileName)
				remoteTempFilePath = fmt.Sprintf("/tmp/%s", testFileName)

				Expect(os.WriteFile(localTempFilePath, []byte(tempFileContent), fs.ModePerm)).To(Succeed())

				GinkgoWriter.Println("Test file <", localTempFilePath, "> written")
			})

			AfterEach(func(ctx context.Context) {
				var localErr error

				_, err := os.Stat(localTempFilePath)
				if err == nil {
					GinkgoWriter.Println("Deleting <", localTempFilePath, ">..")

					Expect(os.Remove(localTempFilePath)).To(Succeed())
				} else {
					if os.IsNotExist(err) {
						GinkgoWriter.Println("Test file <", localTempFilePath, "> does not exist anymore")
						return
					}
					localErr = err
				}

				GinkgoWriter.Println("Deleting <", remoteTempFilePath, ">..")

				suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("rm -f %s", remoteTempFilePath))

				Expect(localErr).ToNot(HaveOccurred())
			})

			It("copies a file from host to Linux node", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "system", "scp", "m", localTempFilePath, "/tmp")

				output := suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("cat %s", remoteTempFilePath))

				Expect(output).To(Equal(tempFileContent))
			})
		})
	})

	Describe("m reverse", func() {
		Context("source file not existing", func() {
			It("returns a warning after failure", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "system", "scp", "m", "/tmp/non-existing.file", "C:\\", "-r")

				Expect(output).To(SatisfyAll(
					MatchRegexp("WARNING"),
					MatchRegexp("Could not copy"),
					MatchRegexp("No such file"),
				))
			})
		})

		Context("target dir not existing", func() {
			const testFileName = "system_scp_m_reverse_test.txt"
			const tempFileContent = "scp-m-reverse-test"
			var remoteTempFilePath string

			BeforeEach(func(ctx context.Context) {
				remoteTempFilePath = fmt.Sprintf("/tmp/%s", testFileName)

				suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("echo %s >> %s", tempFileContent, remoteTempFilePath))

				GinkgoWriter.Println("Test file <", remoteTempFilePath, "> written")
			})

			AfterEach(func(ctx context.Context) {
				GinkgoWriter.Println("Deleting <", remoteTempFilePath, ">..")

				suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("rm -f %s", remoteTempFilePath))
			})

			It("returns a warning after failure", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "system", "scp", "m", remoteTempFilePath, "C:\\temp\\most-likely-not-existent\\", "-r")

				Expect(output).To(SatisfyAll(
					MatchRegexp("WARNING"),
					MatchRegexp("Could not copy"),
				))
			})
		})

		Context("source file and target dir exist", func() {
			const testFileName = "system_scp_m_reverse_test.txt"
			const tempFileContent = "scp-m-reverse-test"
			var localTempFilePath string
			var remoteTempFilePath string

			BeforeEach(func(ctx context.Context) {
				tempDir := GinkgoT().TempDir()
				localTempFilePath = filepath.Join(tempDir, testFileName)
				remoteTempFilePath = fmt.Sprintf("/tmp/%s", testFileName)

				suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("echo %s >> %s", tempFileContent, remoteTempFilePath))

				GinkgoWriter.Println("Test file <", remoteTempFilePath, "> written")
			})

			AfterEach(func(ctx context.Context) {
				var localErr error

				_, err := os.Stat(localTempFilePath)
				if err == nil {
					GinkgoWriter.Println("Deleting <", localTempFilePath, ">..")

					Expect(os.Remove(localTempFilePath)).To(Succeed())
				} else {
					if os.IsNotExist(err) {
						GinkgoWriter.Println("Test file <", localTempFilePath, "> does not exist anymore")
						return
					}
					localErr = err
				}

				GinkgoWriter.Println("Deleting <", remoteTempFilePath, ">..")

				suite.K2sCli().RunOrFail(ctx, "system", "ssh", "m", "--", fmt.Sprintf("rm -f %s", remoteTempFilePath))

				Expect(localErr).ToNot(HaveOccurred())
			})

			It("copies a file from Linux node to host", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "system", "scp", "m", remoteTempFilePath, localTempFilePath, "-r")

				data, err := os.ReadFile(localTempFilePath)
				Expect(err).ToNot(HaveOccurred())

				Expect(string(data)).To(Equal(fmt.Sprintf("%s\n", tempFileContent)))
			})
		})
	})

	Describe("w", func() {
		It("copies a file from host to Windows node", func() {
			Skip("test to be implemented")
		})
	})

	Describe("w reverse", func() {
		It("copies a file from Windows node to host", func() {
			Skip("test to be implemented")
		})
	})
})
