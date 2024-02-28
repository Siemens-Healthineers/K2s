// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests")
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system", func() {
	DescribeTable("print system-not-installed message and exits with non-zero", Label("cli", "system", "scp", "ssh", "m", "w", "acceptance", "no-setup", "ci"),
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("dump", "system", "dump"),
		Entry("scp m", "system", "scp", "m", "a1", "a2"),
		Entry("scp w", "system", "scp", "w", "a1", "a2"),
		Entry("ssh m connect", "system", "ssh", "m"),
		Entry("ssh m cmd", "system", "ssh", "m", "--", "echo yes"),
		Entry("ssh w connect", "system", "ssh", "w"),
		Entry("ssh w cmd", "system", "ssh", "w", "--", "echo yes"),
		Entry("upgrade", "system", "upgrade"),
	)

	Describe("package", Ordered, Label("cli", "system", "package", "acceptance"), func() {
		var testFileName string
		var tempDir string
		var localTempFilePath string

		BeforeEach(func() {
			testFileName = "package.zip"
			tempDir = GinkgoT().TempDir()
			localTempFilePath = filepath.Join(tempDir, testFileName)
		})

		AfterEach(func() {
			_, err := os.Stat(localTempFilePath)
			if err == nil {
				GinkgoWriter.Println("Deleting <", localTempFilePath, ">..")
				Expect(os.Remove(localTempFilePath)).To(Succeed())
			} else {
				if os.IsNotExist(err) {
					GinkgoWriter.Println("Test file <", localTempFilePath, "> does not exist anymore")
					return
				}
			}
		})

		It("generates zip package", func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "system", "package", "--target-dir", tempDir, "--name", testFileName, "--for-offline-installation")

			Expect(output).To(SatisfyAny(
				ContainSubstring("Finished creation of zip package"),
				ContainSubstring("Zip package available as '"+localTempFilePath+"'"),
			))

			file, err := os.Stat(localTempFilePath)
			Expect(err).ToNot(HaveOccurred())
			Expect(file.Size()).To(BeNumerically(">", 0))
		})
	})
})
