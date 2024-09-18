// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests")
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.NoSetupInstalled,
		framework.ClusterTestStepPollInterval(100*time.Millisecond),
		framework.ClusterTestStepTimeout(30*time.Minute))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system", func() {
	DescribeTable("print system-not-installed message and exits with non-zero", Label("cli", "ci", "system", "scp", "ssh", "m", "w", "users", "acceptance", "no-setup"),
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("scp m", "system", "scp", "m", "a1", "a2"),
		Entry("scp w", "system", "scp", "w", "a1", "a2"),
		Entry("ssh m connect", "system", "ssh", "m"),
		Entry("ssh m cmd", "system", "ssh", "m", "--", "echo yes"),
		Entry("ssh w connect", "system", "ssh", "w"),
		Entry("ssh w cmd", "system", "ssh", "w", "--", "echo yes"),
		Entry("upgrade", "system", "upgrade"),
		Entry("users add", "system", "users", "add", "-u", "non-existent"),
	)

	Describe("package", Ordered, Label("cli", "system", "package", "acceptance", "no-setup"), func() {
		Context("valid parameters", func() {
			var zipFilePath string
			var output string

			BeforeAll(func(ctx context.Context) {
				const zipFileName = "package.zip"
				tempDir := GinkgoT().TempDir()
				zipFilePath = filepath.Join(tempDir, zipFileName)

				output = suite.K2sCli().Run(ctx, "system", "package", "--target-dir", tempDir, "--name", zipFileName, "--for-offline-installation", "-o")
			})

			It("generates zip package", func() {
				Expect(output).To(SatisfyAll(
					ContainSubstring("package available"),
					ContainSubstring(zipFilePath),
				))

				file, err := os.Stat(zipFilePath)
				Expect(err).ToNot(HaveOccurred())
				Expect(file.Size()).To(BeNumerically(">", 0))
			})

			It("removes setup config folder", func() {
				_, err := os.Stat(suite.SetupInfo().Config.Host.K2sConfigDir)

				Expect(err).To(MatchError(fs.ErrNotExist))
			})
		})

		Context("invalid parameters", func() {
			It("prints the passed target directory is empty", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "package", "-n", "package.zip")

				Expect(output).To(ContainSubstring("The passed target directory is empty"))
			})

			It("prints the passed zip package name is empty", func(ctx context.Context) {
				tempDir := GinkgoT().TempDir()
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "package", "-d", tempDir)

				Expect(output).To(ContainSubstring("The passed zip package name is empty"))
			})

			It("prints the passed zip package name does not have the extension zip", func(ctx context.Context) {
				tempDir := GinkgoT().TempDir()
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "package", "-d", tempDir, "-n", "package")

				Expect(output).To(ContainSubstring("does not have the extension '.zip'"))
			})
		})
	})

	Describe("k2s is not installed system dump", Ordered, Label("cli", "system", "dump", "acceptance", "no-setup"), func() {
		When("CLI execution successful", func() {
			It("dumps system information", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeSuccess, "system", "dump", "-S")

				Expect(output).To(SatisfyAll(
					ContainSubstring("SUCCESS"),
				))
			})
		})
	})
})
