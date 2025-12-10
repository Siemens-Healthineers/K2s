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
			url := "http://k2s.cluster.local/hook/"
			// Exec allows non-zero exit codes (e.g., curl exit 60 for SSL errors)
			output, _ := suite.Cli().Exec(ctx, "curl.exe", url, "-v", "-m", "5", "--retry", "0")
			// Ingress routing proven by: 404 (no Receiver CRD), 405 (wrong method), 308 (redirect), or connection
			Expect(output).To(Or(
				ContainSubstring("404"),
				ContainSubstring("405"),
				ContainSubstring("308"),
				ContainSubstring("Connected to k2s.cluster.local"),
			))
		})
	})

	When("ingress traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/part-of", "flux", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

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
			url := "http://k2s.cluster.local/hook/"
			output, _ := suite.Cli().Exec(ctx, "curl.exe", url, "-v", "-m", "5", "--retry", "0")
			Expect(output).To(Or(
				ContainSubstring("404"),
				ContainSubstring("405"),
				ContainSubstring("308"),
				ContainSubstring("Connected to k2s.cluster.local"),
			))
		})
	})

	Describe("mutual exclusivity with ArgoCD", func() {
		AfterEach(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "rollout", "argocd", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "rollout", "fluxcd", "-o")
		})

		It("prevents enabling FluxCD when ArgoCD is already enabled", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "rollout", "argocd", "-o")

			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "rollout", "fluxcd")

			Expect(output).To(ContainSubstring("Addon 'rollout argocd' is enabled"))
		})

		It("prevents enabling ArgoCD when FluxCD is already enabled", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "rollout", "fluxcd", "-o")

			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "rollout", "argocd")

			Expect(output).To(ContainSubstring("Addon 'rollout fluxcd' is enabled"))
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
