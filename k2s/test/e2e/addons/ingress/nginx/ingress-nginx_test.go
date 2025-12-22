// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package ingressnginx

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/regex"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s
)

func TestIngressNginx(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress nginx Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress-nginx", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'ingress-nginx' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "delete", "-k", "workloads")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
		k2s.VerifyAddonIsDisabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", "ingress-nginx-test")
	})

	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "ingress", "nginx")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "nginx")

		suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "ingress", "nginx")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable, with http status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through nginx ingress controller", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-nginx-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://albums-linux1.ingress-nginx-test.svc.cluster.local/albums-linux1")

		Expect(err).ToNot(HaveOccurred())
	})

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "nginx")

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+nginx.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The nginx ingress controller is working"),
			MatchRegexp("The external IP for ingress-nginx service is set to %s", regex.IpAddressRegex),
		))

		output = suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "nginx", "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal("ingress"))
		Expect(status.Implementation).To(Equal("nginx"))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsIngressNginxRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The nginx ingress controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsExternalIPSet"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The external IP for ingress-nginx service is set to %s", regex.IpAddressRegex)))),
		))
	})
})
