// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package nginxgw

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework/regex"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

const (
	ingressNginxGwTest = "ingress-nginx-gw-test"
	nginxGw            = "nginx-gw"
)

func TestIngressNginxGw(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress nginx-gw Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress-nginx-gw", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'ingress nginx-gw' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads")
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", nginxGw, "-o")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gateway", nginxGw)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", ingressNginxGwTest)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux2", ingressNginxGwTest)

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", nginxGw)).To(BeFalse())
	})

	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "ingress", nginxGw)

		Expect(output).To(ContainSubstring("already disabled"))
	})

	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", nginxGw)

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+nginx-gw.+ of Addon .+ingress.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", nginxGw, "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("ingress"))
				Expect(status.Implementation).To(Equal(nginxGw))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	It("is in enabled state and pods are in running state", func(ctx context.Context) {
		suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", nginxGw, "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", nginxGw)

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", nginxGw, nginxGw)

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", nginxGw)).To(BeTrue())
	})

	It("creates TLS certificate using temporary cert-manager and cleans up successfully", func(ctx context.Context) {
		// Verify cert-manager namespace does not exist initially
		namespaceList := suite.Kubectl().Run(ctx, "get", "namespace", "-o", "json")
		Expect(namespaceList).NotTo(ContainSubstring("nginx-gw-cert-manager-temp"))

		// Verify the TLS secret exists in nginx-gw namespace (created during enable)
		Eventually(func() string {
			return suite.Kubectl().Run(ctx, "get", "secret", "k2s-cluster-local-tls", "-n", nginxGw, "-o", "json")
		}, testClusterTimeout, "5s").Should(SatisfyAll(
			ContainSubstring("kubernetes.io/tls"),
			ContainSubstring("tls.crt"),
			ContainSubstring("tls.key"),
		))

		GinkgoWriter.Println("TLS secret k2s-cluster-local-tls exists in nginx-gw namespace")

		// Verify cert-manager namespace was deleted after certificate creation
		namespaceList = suite.Kubectl().Run(ctx, "get", "namespace", "-o", "json")
		Expect(namespaceList).NotTo(ContainSubstring("nginx-gw-cert-manager-temp"))

		GinkgoWriter.Println("cert-manager namespace was cleaned up successfully")

		// Verify cert-manager pods do not exist
		podsList := suite.Kubectl().Run(ctx, "get", "pods", "-n", "nginx-gw-cert-manager-temp", "--ignore-not-found")
		Expect(podsList).To(BeEmpty())

		GinkgoWriter.Println("cert-manager pods were cleaned up successfully")

		// Verify cert-manager deployments do not exist
		deploymentsList := suite.Kubectl().Run(ctx, "get", "deployments", "-n", "nginx-gw-cert-manager-temp", "--ignore-not-found")
		Expect(deploymentsList).To(BeEmpty())

		GinkgoWriter.Println("cert-manager deployments were cleaned up successfully")

		// Verify Certificate resource does not exist (should be deleted during cleanup)
		certificatesList := suite.Kubectl().Run(ctx, "get", "certificate", "-n", nginxGw, "--ignore-not-found")
		Expect(certificatesList).NotTo(ContainSubstring("k2s-cluster-local-tls"))

		GinkgoWriter.Println("Certificate resource was cleaned up successfully")

		// Verify Issuer resource does not exist (should be deleted during cleanup)
		issuersList := suite.Kubectl().Run(ctx, "get", "issuer", "-n", nginxGw, "--ignore-not-found")
		Expect(issuersList).NotTo(ContainSubstring("selfsigned-issuer"))

		GinkgoWriter.Println("Issuer resource was cleaned up successfully")
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "ingress", nginxGw)

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable via HTTP, with status NotFound", func(ctx context.Context) {
		url := "http://k2s.cluster.local/"
		httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("makes k2s.cluster.local reachable via HTTPS, with status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through nginx gateway fabric via HTTPRoute", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", ingressNginxGwTest)

		_, err := suite.HttpClient().GetJson(ctx, "http://k2s.cluster.local/albums-linux1")

		Expect(err).ToNot(HaveOccurred())
	})

	It("sample app is reachable through nginx gateway fabric via service", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux2", ingressNginxGwTest)

		_, err := suite.HttpClient().GetJson(ctx, "http://albums-linux2.ingress-nginx-gw-test.svc.cluster.local/albums-linux2")

		Expect(err).ToNot(HaveOccurred())
	})

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", nginxGw)

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+nginx-gw.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The nginx gateway fabric controller is working"),
			MatchRegexp("The external IP for nginx-gw service is set to %s", regex.IpAddressRegex),
		))

		output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", nginxGw, "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal("ingress"))
		Expect(status.Implementation).To(Equal(nginxGw))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsNginxGatewayRunning"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The nginx gateway fabric controller is working")))),
			SatisfyAll(
				HaveField("Name", "IsExternalIPSet"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The external IP for nginx-gw service is set to %s", regex.IpAddressRegex)))),
		))
	})
})
