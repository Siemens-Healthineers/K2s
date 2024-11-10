// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package copy

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestCopy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node copy Acceptance Tests", Label("cli", "node", "copy", "acceptance", "setup-required", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node copy", func() {
	Describe("copy", func() {
		var ipAddress string
		var source string

		BeforeEach(func(ctx context.Context) {
			ipAddress = k2s.GetControlPlane(suite.SetupInfo().Config.Nodes).IpAddress

			GinkgoWriter.Println("Using control-plane IP address <", ipAddress, ">")

			source = GinkgoT().TempDir()
		})

		It("runs into a defined timeout", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", ipAddress, "-s", source, "-t", "", "-o", "--timeout", "5s", "-u", "")

			Expect(output).To(SatisfyAll(
				MatchRegexp("ERROR"),
				MatchRegexp("timeout"),
			))
		}, SpecTimeout(time.Second*6)) // 1s grace period for k2s.exe
	})
})
