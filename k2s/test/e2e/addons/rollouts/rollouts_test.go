// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package rollouts

import (
	"context"
	"encoding/json"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 20

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	linuxOnly             = false
)

func Testrollouts(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollouts Addon Acceptance Tests", Label("rollouts", "acceptance", "setup-required", "invasive", "rollouts", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'rollouts' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "rollouts", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollouts", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "rollouts")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().Run(ctx, "addons", "status", "rollouts")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+rollouts.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().Run(ctx, "addons", "status", "rollouts", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("rollouts"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "rollouts", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollouts", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollouts")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollouts")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "rollouts", "port-forward", "svc/argocd-server", "8080:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8080/rollouts/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "rollouts", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollouts", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "rollouts", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollouts", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollouts")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollouts")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollouts/", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollouts/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "rollouts", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollouts", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "rollouts", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollouts")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollouts", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollouts")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollouts")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollouts")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollouts")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollouts", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollouts")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollouts/", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollouts/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", "rollouts")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+rollouts.+ is .+enabled.+`),
		MatchRegexp("ArgoCD Application Set Controller is working"),
		MatchRegexp("ArgoCD Dex Server is working"),
		MatchRegexp("ArgoCD Notification Controller is working"),
		MatchRegexp("ArgoCD Redis DB is working"),
		MatchRegexp("ArgoCD Repo Server is working"),
		MatchRegexp("ArgoCD Server is working"),
		MatchRegexp("ArgoCD Application Server is working"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", "rollouts", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("rollouts"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsArgoCDApplicationsetControllerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("ArgoCD Application Set Controller is working")))),
		SatisfyAll(
			HaveField("Name", "IsArgoCDDexServerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Dex Server is working")))),
		SatisfyAll(
			HaveField("Name", "IsArgoCDNotificationControllerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Notification Controller is working")))),
		SatisfyAll(
			HaveField("Name", "IsArgoCDRedisRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Redis DB is working")))),
		SatisfyAll(
			HaveField("Name", "IsArgoCDRepoServerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Repo Server is working")))),
		SatisfyAll(
			HaveField("Name", "IsArgoCDServerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Server is working")))),
		SatisfyAll(
			HaveField("Name", "AreStatefulsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("ArgoCD Application Server is working")))),
	))
}
