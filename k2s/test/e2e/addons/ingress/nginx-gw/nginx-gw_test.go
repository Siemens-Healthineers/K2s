// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package nginxgw

import (
	"context"
	"encoding/json"
	"os"
	"path"
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
		suite.Kubectl().Run(ctx, "delete", "-k", "workloads", "--ignore-not-found")
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", nginxGw, "-o")

		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())

		output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
		Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))

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

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})

	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
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
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
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
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available")))),
		))
	})

	It("does not remove cert-manager when security addon is enabled", func(ctx context.Context) {
		// Enable security addon
		suite.K2sCli().RunOrFail(ctx, "addons", "enable", "security", "-o")
		suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")
		suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager-webhook", "cert-manager")

		// Disable ingress nginx-gw
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", nginxGw, "-o")

		// Verify cert-manager is still present
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil(), "cmctl.exe should still exist when security addon is enabled")

		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should still exist when security addon is enabled")

		suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")
		suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager-webhook", "cert-manager")

		// Clean up - disable security addon
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "cert-manager", "cert-manager")
	})

	It("removes cert-manager when security addon is not enabled", func(ctx context.Context) {
		// Re-enable ingress nginx-gw to have cert-manager installed
		suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", nginxGw, "-o")
		suite.Cluster().ExpectDeploymentToBeAvailable("cert-manager", "cert-manager")

		// Verify cert-manager is present
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil(), "cmctl.exe should exist before disabling")

		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should exist before disabling")

		// Disable ingress nginx-gw (without security addon enabled)
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", nginxGw, "-o")

		// Verify cert-manager is removed
		_, err = os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue(), "cmctl.exe should be removed when security addon is not enabled")

		output = suite.Kubectl().Run(ctx, "get", "secrets", "-A")
		Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"), "CA root certificate should be removed when security addon is not enabled")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "cert-manager", "cert-manager")
	})
})
