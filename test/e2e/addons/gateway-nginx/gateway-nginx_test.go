// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package gatewaynginx

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"k2sTest/framework"
	"k2sTest/framework/k8s"
	"net/http"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
)

const (
	testClusterTimeout = time.Minute * 10
	retryCount         = 3
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

func TestGatewayNginx(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, fmt.Sprintf("gateway-nginx Addon Acceptance Tests"), Label("addon", "acceptance", "setup-required", "invasive", "gateway-nginx"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'gateway-nginx' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.K2sCli().Run(ctx, "addons", "disable", "gateway-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "gateway-nginx-test")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gateway", "nginx-gateway")

		status := suite.K2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("gateway-nginx")).To(BeFalse())
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "enable", "gateway-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gateway", "nginx-gateway")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "nginx-gateway", "nginx-gateway")

		status := suite.K2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("gateway-nginx")).To(BeTrue())
	})

	It("sample app is reachable through gateway api", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "gateway-nginx-test")

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
