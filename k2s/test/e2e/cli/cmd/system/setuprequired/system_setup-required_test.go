// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package systemrequired

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests", Label("cli", "system", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("system", Ordered, func() {
	Describe("package", Label("package"), func() {
		It("prints system-installed-error and exits", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "system", "package", "--target-dir", ".", "--name", "package.zip")

			Expect(output).To(SatisfyAll(
				ContainSubstring("is installed"),
				ContainSubstring("Please uninstall"),
			))
		})
	})

	Describe("upgrade", Label("upgrade", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				result := k2s.ShowStatus(ctx)

				result.VerifyWrongK8sContextFailure()
			})
		})
	})
})
