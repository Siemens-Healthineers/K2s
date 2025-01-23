// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package exec

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
)

var suite *framework.K2sTestSuite
var skipWinNodeTests bool

func TestExec(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node exec Acceptance Tests", Label("cli", "node", "exec", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	// TODO: remove when multivm connects with same SSH key to win node as to control-plane
	skipWinNodeTests = true //suite.SetupInfo().SetupConfig.SetupName != setupinfo.SetupNameMultiVMK8s || suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node exec", Ordered, func() {
	When("node is Linux node", Label("linux-node"), func() {
		const remoteUser = "remote"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			nodeIpAddress = k2s.GetControlPlane(suite.SetupInfo().Config.Nodes()).IpAddress()

			GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
		})

		When("command execution succeeds", func() {
			It("prints the output and exits with exit code zero", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-o")

				Expect(output).To(MatchRegexp("Hello, world!"))
			})
		})

		When("command execution failes", func() {
			It("prints the output and exits with non-zero exit code", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "mkdir /this/should/not/exist", "-o")

				Expect(output).To(MatchRegexp("cannot create directory"))
			})
		})
	})

	When("node is Windows node", Label("windows-node"), func() {
		const remoteUser = "administrator"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			if skipWinNodeTests {
				Skip("Windows node tests are skipped")
			}

			nodeIpAddress = k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes()).IpAddress()

			GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")
		})

		When("command execution succeeds", func() {
			It("prints the output and exits with exit code zero", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "echo 'Hello, world!'", "-o")

				Expect(output).To(MatchRegexp("Hello, world!"))
			})
		})

		When("command execution failes", func() {
			It("prints the output and exits with non-zero exit code", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "exec", "-i", nodeIpAddress, "-u", remoteUser, "-c", "non-existing-cmd", "-o")

				Expect(output).To(MatchRegexp("not recognized"))
			})
		})
	})
})
