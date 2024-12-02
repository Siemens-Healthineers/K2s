// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package connect

import (
	"context"
	"io"
	"os/exec"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gbytes"
	"github.com/onsi/gomega/gexec"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var skipWinNodeTests bool

func TestConnect(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node connect Acceptance Tests", Label("cli", "node", "connect", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	// TODO: remove when multivm connects with same SSH key to win node as to control-plane
	skipWinNodeTests = true //suite.SetupInfo().SetupConfig.SetupName != setupinfo.SetupNameMultiVMK8s || suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node connect", Ordered, func() {
	When("node is Linux node", Label("linux-node"), func() {
		const remoteUser = "remote"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			nodeIpAddress = k2s.GetControlPlane(suite.SetupInfo().Config.Nodes).IpAddress

			GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
		})

		It("connects via SSH successfully", func(ctx context.Context) {
			inputReader, inputWriter := io.Pipe()

			cmd := exec.CommandContext(ctx, "k2s.exe", "node", "connect", "-i", nodeIpAddress, "-u", remoteUser, "-o")
			cmd.Stdin = inputReader

			session, err := gexec.Start(cmd, GinkgoWriter, GinkgoWriter)
			Expect(err).NotTo(HaveOccurred())

			GinkgoWriter.Println("Waiting for pseuto terminal to be ready")

			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(remoteUser + "@.+"))

			GinkgoWriter.Println("Closing pseudo terminal")

			_, err = inputWriter.Write([]byte("logout\n"))
			Expect(err).NotTo(HaveOccurred())

			Expect(inputWriter.Close()).To(Succeed())

			GinkgoWriter.Println("Waiting for pseudo terminal to be closed")

			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(`logout`))
			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gbytes.Say(`Command 'connect' done.`))
			Eventually(ctx, session).WithTimeout(time.Second * 5).Should(gexec.Exit(0))
		})
	})

	When("node is Windows node", Label("windows-node"), func() {
		// const remoteUser = "administrator"

		var nodeIpAddress string

		BeforeEach(func(ctx context.Context) {
			if skipWinNodeTests {
				Skip("Windows node tests are skipped")
			}

			Skip("not implemented yet")

			nodeIpAddress = k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes).IpAddress

			GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")
		})
	})
})
