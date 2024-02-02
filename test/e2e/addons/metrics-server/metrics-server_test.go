// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package metricsserver

import (
	"context"
	"k2sTest/framework"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "metrics-server Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "metrics-server", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'metrics-server' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "disable", "metrics-server", "-o")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "metrics-server", "kube-system")

		status := suite.K2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("metrics-server")).To(BeFalse())
	})

	It("prints already-disabled message on disable command", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "disable", "metrics-server")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "enable", "metrics-server", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "kube-system")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "kube-system")

		status := suite.K2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("metrics-server")).To(BeTrue())
	})

	It("prints already-enabled message on enable command", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "enable", "metrics-server")

		Expect(output).To(ContainSubstring("already enabled"))
	})
})
