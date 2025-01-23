// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package setuprequired

import (
	"context"
	"time"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node CLI Command Acceptance Tests", Label("cli", "node", "acceptance", "setup-required", "invasive"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("node", Ordered, func() {
	Describe("add", Label("add"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				result := k2s.RunNodeAddCmd(ctx)

				result.VerifyFailureDueToWrongK8sContext()
			})
		})
	})

	Describe("remove", Label("remove"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				result := k2s.RunNodeRemoveCmd(ctx)

				result.VerifyFailureDueToWrongK8sContext()
			})
		})
	})
})
