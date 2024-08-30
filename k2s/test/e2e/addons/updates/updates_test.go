// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package updates

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

func TestUpdates(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "updates Addon Acceptance Tests", Label("updates", "acceptance", "setup-required", "invasive", "updates", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'updates' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "updates", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "updates", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "updates")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().Run(ctx, "addons", "status", "updates")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+updates.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().Run(ctx, "addons", "status", "updates", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("updates"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "updates", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "updates", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "updates")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "updates")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "updates", "port-forward", "svc/argocd-server", "8080:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8080/updates/"
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
			suite.K2sCli().Run(ctx, "addons", "disable", "updates", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "updates", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "updates", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "updates", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "updates")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "updates")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/updates/", func(ctx context.Context) {
			url := "https://k2s.cluster.local/updates/"
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
			suite.K2sCli().Run(ctx, "addons", "disable", "updates", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "updates", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "updates", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "updates")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "updates", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "updates")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "updates")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "updates")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "updates")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("updates", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "updates")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/updates/", func(ctx context.Context) {
			url := "https://k2s.cluster.local/updates/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", "updates")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+updates.+ is .+enabled.+`),
		MatchRegexp("ArgoCD Application Set Controller is working"),
		MatchRegexp("ArgoCD Dex Server is working"),
		MatchRegexp("ArgoCD Notification Controller is working"),
		MatchRegexp("ArgoCD Redis DB is working"),
		MatchRegexp("ArgoCD Repo Server is working"),
		MatchRegexp("ArgoCD Server is working"),
		MatchRegexp("ArgoCD Application Server is working"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", "updates", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("updates"))
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
