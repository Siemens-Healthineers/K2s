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
				output := suite.K2sCli().RunOrFail(ctx, "image", "registry", "ls")

				Expect(output).To(SatisfyAny(
					ContainSubstring("No registries configured"),
					ContainSubstring("Configured registries"),
				))
			})
		})
	})

	Describe("rm", Label("rm", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				result := k2s.RunImageRmCmd(ctx)

				result.VerifyFailureDueToWrongK8sContext()
			})
		})
	})
})
