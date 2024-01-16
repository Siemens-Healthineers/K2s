// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package ingressnginx

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
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

func TestIngressNginx(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, fmt.Sprintf("ingress-nginx Addon Acceptance Tests"), Label("addon", "acceptance", "setup-required", "invasive", "ingress-nginx"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'ingress-nginx' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.k2sCli().Run(ctx, "addons", "disable", "ingress-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "ingress-nginx-test")

		status := suite.k2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("ingress-nginx")).To(BeFalse())
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.k2sCli().Run(ctx, "addons", "enable", "ingress-nginx", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

		status := suite.k2sCli().GetStatus(ctx)
		Expect(status.IsAddonEnabled("ingress-nginx")).To(BeTrue())
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
