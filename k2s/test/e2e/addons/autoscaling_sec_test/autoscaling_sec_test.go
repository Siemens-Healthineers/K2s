// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package autoscaling_sec

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const autoscalingSecTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestAutoscalingSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Autoscaling and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "autoscaling", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(autoscalingSecTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
	if k2s.IsAddonEnabled("security") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}
	if k2s.IsAddonEnabled("ingress", "nginx") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}
	suite.TearDown(ctx)
})

var _ = Describe("'autoscaling and security enhanced' addons", Ordered, func() {
	Describe("Security addon activated first then autoscaling addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("activates the autoscaling addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "autoscaling")
		})

		It("verifies autoscaling deployment is available and pods are ready", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "autoscaling", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Autoscaling addon activated first then security addon", func() {
		It("activates the autoscaling addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "autoscaling", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("verifies autoscaling deployment is available and pods are ready", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("keda-admission", "autoscaling")
			suite.Cluster().ExpectPodsInReadyState(ctx, "app=keda-admission-webhooks", "autoscaling")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "autoscaling")
		})
	})
})
