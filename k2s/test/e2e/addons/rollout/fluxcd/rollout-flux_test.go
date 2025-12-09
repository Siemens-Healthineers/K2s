// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package rolloutfluxcd

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite     *framework.K2sTestSuite
	linuxOnly = false
)

func TestRolloutFluxCD(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout fluxcd Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout-fluxcd", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'rollout fluxcd' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "fluxcd", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "fluxcd")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "fluxcd")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Implementation .+fluxcd.+ of Addon .+rollout.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "fluxcd", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("rollout"))
					Expect(status.Implementation).To(Equal("fluxcd"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("helm-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("notification-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-reflector-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-automation-controller", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "source-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kustomize-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "helm-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "notification-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-reflector-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-automation-controller", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "fluxcd")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})
	})

	When("ingress nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "fluxcd")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("source-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("kustomize-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("helm-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("notification-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-reflector-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("image-automation-controller", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "source-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "kustomize-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "helm-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "notification-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-reflector-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "image-automation-controller", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "fluxcd")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("webhook receiver is accessible through ingress", func(ctx context.Context) {
			// Note: FluxCD has no web UI. Ingress exposes webhook-receiver for Git push notifications.
			url := "http://k2s.cluster.local/hook/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-I", "-m", "5", "--retry", "3", "-L", "-o", "/dev/null", "-w", "%{http_code}")
			// Expect 404 (no Receiver CRD configured) or 308 (redirect) - proves ingress routing works
			Expect(httpStatus).To(MatchRegexp("404|308"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "fluxcd")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Implementation .+fluxcd.+ of Addon .+rollout.+ is .+enabled.+`),
		MatchRegexp("Flux Source Controller is working"),
		MatchRegexp("Flux Kustomize Controller is working"),
		MatchRegexp("Flux Helm Controller is working"),
		MatchRegexp("Flux Notification Controller is working"),
	))

	output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "fluxcd", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("rollout"))
	Expect(status.Implementation).To(Equal("fluxcd"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
}
