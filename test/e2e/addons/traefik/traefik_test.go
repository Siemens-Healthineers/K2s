// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package traefik

import (
	"context"
	"encoding/json"
	"io"
	"k2sTest/framework"
	"net/http"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "traefik Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'traefik' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.K2sCli().Run(ctx, "addons", "disable", "traefik", "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "traefik")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "traefik-test")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("traefik")).To(BeFalse())
	})

	It("prints already-disabled message", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "disable", "traefik")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "enable", "traefik", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "traefik")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "traefik")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("traefik")).To(BeTrue())
	})

	It("prints already-enabled message", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "enable", "traefik")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("sample app is reachable through traefik ingress controller", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "traefik-test")

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
