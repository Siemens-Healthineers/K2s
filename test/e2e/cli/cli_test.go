// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ls

import (
	"context"
	"os/exec"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"

	"k2sTest/framework"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "CLI Acceptance Tests", Label("cli", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("CLI", func() {
	When("error happened while CLI executions", Ordered, func() {
		var output string
		var exitCode int

		BeforeAll(func(ctx context.Context) {
			erroneousCmd := exec.Command(suite.K2sCli().Path(), "invalid", "command")
			session, err := gexec.Start(erroneousCmd, GinkgoWriter, GinkgoWriter)

			Expect(err).ToNot(HaveOccurred())

			Eventually(session,
				suite.TestStepTimeout(),
				suite.TestStepPollInterval(),
				ctx).Should(gexec.Exit())

			output = string(session.Out.Contents())
			exitCode = session.ExitCode()
		})

		It("prints the error", func() {
			Expect(output).To(SatisfyAll(
				ContainSubstring("ERROR"),
				ContainSubstring(`unknown command "invalid"`),
			))
		})

		It("returns non-zero exit code", func() {
			Expect(exitCode).ToNot(Equal(0))
		})
	})

	When("CLI execution successful", Ordered, func() {
		var output string
		var exitCode int

		BeforeAll(func(ctx context.Context) {
			erroneousCmd := exec.Command(suite.K2sCli().Path(), "addons", "ls")
			session, err := gexec.Start(erroneousCmd, GinkgoWriter, GinkgoWriter)

			Expect(err).ToNot(HaveOccurred())

			Eventually(session,
				suite.TestStepTimeout(),
				suite.TestStepPollInterval(),
				ctx).Should(gexec.Exit())

			output = string(session.Out.Contents())
			exitCode = session.ExitCode()
		})

		It("prints no error", func() {
			Expect(output).ToNot(ContainSubstring("ERROR"))
			Expect(output).To(ContainSubstring("Available Addons"))
		})

		It("returns zero exit code", func() {
			Expect(exitCode).To(Equal(0))
		})
	})

	When("non-leaf command is issued", Ordered, func() {
		var output string
		var exitCode int

		BeforeAll(func(ctx context.Context) {
			erroneousCmd := exec.Command(suite.K2sCli().Path(), "addons")
			session, err := gexec.Start(erroneousCmd, GinkgoWriter, GinkgoWriter)

			Expect(err).ToNot(HaveOccurred())

			Eventually(session,
				suite.TestStepTimeout(),
				suite.TestStepPollInterval(),
				ctx).Should(gexec.Exit())

			output = string(session.Out.Contents())
			exitCode = session.ExitCode()
		})

		It("prints help without errors", func() {
			Expect(output).ToNot(ContainSubstring("ERROR"))
			Expect(output).To(ContainSubstring("Addons add optional functionality"))
		})

		It("returns zero exit code", func() {
			Expect(exitCode).To(Equal(0))
		})
	})

	When("help flag is used", Ordered, func() {
		var output string
		var exitCode int

		BeforeAll(func(ctx context.Context) {
			erroneousCmd := exec.Command(suite.K2sCli().Path(), "addons", "ls", "-h")
			session, err := gexec.Start(erroneousCmd, GinkgoWriter, GinkgoWriter)

			Expect(err).ToNot(HaveOccurred())

			Eventually(session,
				suite.TestStepTimeout(),
				suite.TestStepPollInterval(),
				ctx).Should(gexec.Exit())

			output = string(session.Out.Contents())
			exitCode = session.ExitCode()
		})

		It("prints help without errors", func() {
			Expect(output).ToNot(ContainSubstring("ERROR"))
			Expect(output).To(ContainSubstring("List addons available"))
		})

		It("returns zero exit code", func() {
			Expect(exitCode).To(Equal(0))
		})
	})
})
