// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package proxy_test

import (
	"context"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestProxy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system proxy CLI Commands Acceptance Tests", Label("cli", "system", "proxy", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system proxy", func() {
	Describe("read-only commands", Label("cli", "system", "proxy", "acceptance", "setup-required", "system-running"), func() {
		It("show prints proxy information", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "show")

			Expect(output).To(SatisfyAll(
				ContainSubstring("Proxy:"),
				ContainSubstring("Proxy Overrides:"),
			))
		})

		It("get exits successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "get")
		})

		It("override ls exits successfully", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "ls")
		})
	})

	Describe("argument validation", Label("cli", "system", "proxy", "acceptance", "setup-required", "system-running"), func() {
		It("set with no args prints error", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "proxy", "set")

			Expect(output).To(ContainSubstring("incorrect number of arguments"))
		})

		It("override add with no args prints error", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "proxy", "override", "add")

			Expect(output).To(ContainSubstring("incorrect number of arguments"))
		})

		It("override delete with no args prints error", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "system", "proxy", "override", "delete")

			Expect(output).To(ContainSubstring("incorrect number of arguments"))
		})
	})

	Describe("round-trip", Ordered, Label("cli", "system", "proxy", "acceptance", "setup-required", "system-running", "invasive"), func() {
		var savedProxy string

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "get")
			savedProxy = strings.TrimSpace(output)
			GinkgoWriter.Println("Saved original proxy config:", savedProxy)
		})

		AfterAll(func(ctx context.Context) {
			if savedProxy != "" {
				GinkgoWriter.Println("Restoring original proxy config:", savedProxy)
				suite.K2sCli().MustExec(ctx, "system", "proxy", "set", savedProxy)
			} else {
				GinkgoWriter.Println("No proxy was configured before test, resetting")
				suite.K2sCli().MustExec(ctx, "system", "proxy", "reset")
			}
		})

		It("set configures the proxy", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "set", "http://test-proxy:8080")
		})

		It("get returns the configured proxy", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "get")

			Expect(output).To(ContainSubstring("http://test-proxy:8080"))
		})

		It("show displays the configured proxy", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "show")

			Expect(output).To(ContainSubstring("http://test-proxy:8080"))
		})

		It("override add adds an override", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "add", "test.local")
		})

		It("override ls lists the added override", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "ls")

			Expect(output).To(ContainSubstring("test.local"))
		})

		It("override delete removes the override", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "delete", "test.local")
		})

		It("override ls no longer lists the removed override", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "override", "ls")

			Expect(output).NotTo(ContainSubstring("test.local"))
		})

		It("reset clears the proxy configuration", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "system", "proxy", "reset")
		})

		It("show confirms proxy is cleared after reset", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "system", "proxy", "show")

			Expect(output).To(ContainSubstring("Proxy: <not configured>"))
		})
	})
})
