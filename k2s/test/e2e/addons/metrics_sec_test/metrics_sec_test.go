// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package metrics_sec

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestMetricsSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "metrics Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "metrics", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o", "--ignore-not-found")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

	suite.TearDown(ctx)
})

var _ = Describe("'metrics and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then metrics addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("activates the metrics addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
		})

		It("verifies that the metrics deployment is available and pods are ready", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "metrics")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "metrics", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Metrics addon activated first then security addon", func() {
		It("activates the metrics addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "metrics", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("verifies that the metrics deployment is available and pods are ready", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "metrics")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "metrics")
		})
	})
})
