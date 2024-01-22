// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package dashboard

import (
	"context"
	"fmt"
	"k2sTest/framework"
	"k2sTest/framework/k8s"
	"os/exec"
	"path"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

const (
	testClusterTimeout = time.Minute * 10
)

var (
	suite                 *framework.K2sTestSuite
	kubectl               *k8s.Kubectl
	cluster               *k8s.Cluster
	linuxOnly             bool
	exportPath            string
	addons                []string
	portForwardingSession *gexec.Session
)

func TestDashboard(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, fmt.Sprintf("dasboard Addon Acceptance Tests"), Label("addon", "acceptance", "setup-required", "invasive", "dashboard"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'dashboard' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "kubernetes-dashboard", "port-forward", "svc/kubernetes-dashboard", "8443:443")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "https://localhost:8443/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "traefik")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through traefik", func(ctx context.Context) {
			url := "https://k2s-dashboard.local/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress-nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectDeploymentToBeAvailable("dashboard-metrics-scraper", "kubernetes-dashboard")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "kubernetes-dashboard", "kubernetes-dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "dashboard-metrics-scraper", "kubernetes-dashboard")

			status := suite.K2sCli().GetStatus(ctx)
			Expect(status.IsAddonEnabled("dashboard")).To(BeTrue())
		})

		It("is reachable through ingress-nginx", func(ctx context.Context) {
			url := "https://k2s-dashboard.local/#/pod?namespace=_all"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})
})
