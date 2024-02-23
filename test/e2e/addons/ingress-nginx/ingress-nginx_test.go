// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package ingressnginx

import (
	"context"
	"encoding/json"
	"io"
	"k2sTest/framework"
	"k2sTest/framework/k2s"
	"net/http"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestIngressNginx(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress-nginx Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "ingress-nginx", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'ingress-nginx' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.K2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "ingress-nginx-test")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress-nginx")).To(BeFalse())
	})

	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "ingress-nginx")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "enable", "ingress-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress-nginx")).To(BeTrue())
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "ingress-nginx")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("sample app is reachable through ingress-nginx ingress controller", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-test")

		url := "http://172.19.1.100/albums-linux1"
		res, err := httpGet(url, 5)

		Expect(err).ShouldNot(HaveOccurred())
		Expect(res).To(SatisfyAll(
			HaveHTTPStatus(http.StatusOK),
			HaveHTTPHeaderWithValue("Content-Type", "application/json; charset=utf-8"),
		))

		defer res.Body.Close()

		data, err := io.ReadAll(res.Body)

		Expect(err).ShouldNot(HaveOccurred())
		Expect(json.Valid(data)).To(BeTrue())
	})
})

func httpGet(url string, retryCount int) (*http.Response, error) {
	var res *http.Response
	var err error
	for i := 0; i < retryCount; i++ {
		GinkgoWriter.Println("retry count: ", retryCount)
		res, err = http.Get(url)

		if err == nil && res.StatusCode == 200 {
			return res, err
		}

		time.Sleep(time.Second * 1)
	}

	return res, err
}
