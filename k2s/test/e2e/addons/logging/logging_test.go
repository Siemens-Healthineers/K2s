// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package logging

import (
	"context"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

const testClusterTimeout = time.Minute * 20

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	linuxOnly             = false
)

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "logging Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "logging", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'logging' addon", Ordered, func() {
	When("no ingress controller is configured", func() {
		AfterAll(func(ctx context.Context) {
			portForwardingSession.Kill()
			suite.K2sCli().Run(ctx, "addons", "disable", "logging", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeFalse())
		})

		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "logging")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "logging", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "exe", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "logging", "port-forward", "svc/opensearch-dashboards", "5601:5601")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "http://localhost:5601"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("302"))
		})
	})

	When("traefik as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "traefik", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "traefik")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "traefik", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "traefik")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "logging", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("is reachable through traefik", func(ctx context.Context) {
			url := "http://k2s-logging.local"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("302"))
		})
	})

	Describe("ingress-nginx as ingress controller", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "ingress-nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "disable", "logging", "-o")
			suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
			suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
			}

			suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeFalse())
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().Run(ctx, "addons", "enable", "logging", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
			suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
			suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
			if !linuxOnly {
				suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
			}

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("logging")).To(BeTrue())
		})

		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("is reachable through ingress-nginx", func(ctx context.Context) {
			url := "http://k2s-logging.local"
			httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "3", "--fail")
			Expect(httpStatus).To(ContainSubstring("302"))
		})
	})
})
