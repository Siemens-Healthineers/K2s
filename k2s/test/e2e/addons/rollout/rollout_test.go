// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package rollout

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

func TestRollout(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "rollout", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'rollout' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "rollout")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+rollout.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("rollout"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			args := []string{"addons", "enable", "rollout", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollout")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "rollout", "port-forward", "svc/argocd-server", "8080:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8080/rollout/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			args := []string{"addons", "enable", "rollout", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollout")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollout", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollout/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "rollout", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeDeleted("argocd-application-controller", "rollout", ctx)

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			args := []string{"addons", "enable", "rollout", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-applicationset-controller", "rollout")

			suite.Cluster().ExpectStatefulSetToBeReady("argocd-application-controller", "rollout", 1, ctx)

			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-dex-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-redis", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-repo-server", "rollout")
			suite.Cluster().ExpectDeploymentToBeAvailable("argocd-server", "rollout")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-applicationset-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-application-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-dex-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-notifications-controller", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-redis", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-repo-server", "rollout")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "argocd-server", "rollout")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("rollout", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "rollout")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/rollout", func(ctx context.Context) {
			url := "https://k2s.cluster.local/rollout/"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+rollout.+ is .+enabled.+`),
		MatchRegexp("ArgoCD Application Set Controller is working"),
		MatchRegexp("ArgoCD Dex Server is working"),
		MatchRegexp("ArgoCD Notification Controller is working"),
		MatchRegexp("ArgoCD Redis DB is working"),
		MatchRegexp("ArgoCD Repo Server is working"),
		MatchRegexp("ArgoCD Server is working"),
		MatchRegexp("ArgoCD Application Server is working"),
	))

	output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "rollout", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("rollout"))
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
