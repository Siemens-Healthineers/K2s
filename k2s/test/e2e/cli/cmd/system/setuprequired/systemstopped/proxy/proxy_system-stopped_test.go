// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestProxy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system proxy CLI Commands Acceptance Tests", Label("cli", "system", "proxy", "acceptance", "setup-required", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system proxy", func() {
	Describe("read-only commands succeed when system is stopped", Label("cli", "system", "proxy", "acceptance", "setup-required", "system-stopped"), func() {
		It("get exits successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "get")
		})

		It("show prints proxy information", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "show")

			Expect(output).To(SatisfyAll(
				ContainSubstring("Proxy:"),
				ContainSubstring("Proxy Overrides:"),
			))
		})

		It("override ls exits successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "ls")
		})
	})
})
