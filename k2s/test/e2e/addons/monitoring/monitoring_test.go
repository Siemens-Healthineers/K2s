// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package monitoring

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
)

func TestMonitoring(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "monitoring Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "monitoring", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'monitoring' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "monitoring", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "monitoring")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "monitoring", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "monitoring")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "monitoring", "port-forward", "svc/kube-prometheus-stack-plutono", "3000:80")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "http://localhost:3000/monitoring/login"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "monitoring", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "monitoring")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/monitoring", func(ctx context.Context) {
			url := "https://k2s.cluster.local/monitoring/login"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})

	Describe("nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "monitoring", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "monitoring")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through k2s.cluster.local/monitoring", func(ctx context.Context) {
			url := "https://k2s.cluster.local/monitoring/login"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10", "--fail")
			Expect(httpStatus).To(ContainSubstring("200"))
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", "monitoring")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+monitoring.+ is .+enabled.+`),
		MatchRegexp("The Kube State Metrics Deployment is working"),
		MatchRegexp("The Prometheus Operator is working"),
		MatchRegexp("The Plutono Dashboard is working"),
		MatchRegexp("Prometheus and Alertmanager are working"),
		MatchRegexp("Node Exporter is working"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", "monitoring", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("monitoring"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsKubeStateMetricsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The Kube State Metrics Deployment is working")))),
		SatisfyAll(
			HaveField("Name", "IsPrometheusOperatorRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("The Prometheus Operator is working")))),
		SatisfyAll(
			HaveField("Name", "IsPlutonoRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("The Plutono Dashboard is working")))),
		SatisfyAll(
			HaveField("Name", "AreStatefulsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Prometheus and Alertmanager are working")))),
		SatisfyAll(
			HaveField("Name", "AreDaemonsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Node Exporter is working")))),
	))
}
