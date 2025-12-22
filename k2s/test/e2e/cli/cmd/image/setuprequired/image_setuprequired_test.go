// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package setuprequired

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("image", func() {
	Describe("registry", Label("registry"), func() {
		Describe("ls", Label("ls"), func() {
			It("runs without error", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")

				Expect(output).To(SatisfyAny(
					ContainSubstring("No registries configured"),
					ContainSubstring("Configured registries"),
				))
			})
		})
	})

	Describe("rm", Label("rm", "invasive"), func() {
		When("functionality is not supported in setup type", func() {
			It("fails", func(ctx context.Context) {
				if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
					Skip("setup type must be Linux-only")
				}

				result := k2s.RemoveImage(ctx)

				result.VerifyFunctionalityNotAvailableFailure()
			})
		})

		When("functionality is supported in setup type", func() {
			When("wrong K8s context is in use", func() {
				BeforeEach(func(ctx context.Context) {
					if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
						Skip("setup type must not be Linux-only")
					}

					k2s.SetWrongK8sContext(ctx)

					DeferCleanup(k2s.ResetK8sContext)
				})

				It("fails", func(ctx context.Context) {
					result := k2s.RemoveImage(ctx)

					result.VerifyWrongK8sContextFailure()
				})
			})
		})
	})
})
