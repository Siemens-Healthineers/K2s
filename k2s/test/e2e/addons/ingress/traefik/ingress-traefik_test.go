// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefik

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
	"github.com/siemens-healthineers/k2s/test/framework/regex"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestIngressTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress traefik Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'ingress traefik' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "ingress-traefik-test")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", "traefik")).To(BeFalse())
	})

	It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "ingress", "traefik")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("ingress"))
				Expect(status.Implementation).To(Equal("traefik"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "traefik", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", "traefik")).To(BeTrue())
	})

	It("prints already-enabled message and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable, with http status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through traefik ingress controller", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

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

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "status", "ingress", "traefik")

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The traefik ingress controller is working"),
			MatchRegexp("The external IP for traefik service is set to %s", regex.IpAddressRegex),
		))

		output = suite.K2sCli().Run(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal("ingress"))
		Expect(status.Implementation).To(Equal("traefik"))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsTraefikRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The traefik ingress controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsExternalIPSet"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The external IP for traefik service is set to %s", regex.IpAddressRegex)))),
		))
	})
})

func httpGet(url string, retryCount int) (*http.Response, error) {
	var res *http.Response
	var err error
	for i := 0; i < retryCount; i++ {
		GinkgoWriter.Println("retry count: ", i+1)
		res, err = http.Get(url)

		if err == nil && res.StatusCode == 200 {
			return res, err
		}

		time.Sleep(time.Second * 1)
	}

	return res, err
}
