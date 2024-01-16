// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package metricsserver

import (
	"context"
	"fmt"
	"k2sTest/framework"
	"k2sTest/framework/k8s"
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
	suite                 *framework.k2sTestSuite
	kubectl               *k8s.Kubectl
	cluster               *k8s.Cluster
	linuxOnly             bool
	exportPath            string
	addons                []string
	portForwardingSession *gexec.Session
)

func TestTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, fmt.Sprintf("metrics-server Addon Acceptance Tests"), Label("addon", "acceptance", "setup-required", "invasive", "metrics-server"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'metrics-server' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.k2sCli().Run(ctx, "addons", "disable", "metrics-server", "-o")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "k8s-app", "metrics-server", "kube-system")

		status := suite.k2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("metrics-server")).To(BeFalse())
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.k2sCli().Run(ctx, "addons", "enable", "metrics-server", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("metrics-server", "kube-system")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "k8s-app", "metrics-server", "kube-system")

		status := suite.k2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("metrics-server")).To(BeTrue())
	})
})
