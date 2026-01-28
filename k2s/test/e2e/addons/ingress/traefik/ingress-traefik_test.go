// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefik

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
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/regex"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const (
	testClusterTimeout = time.Minute * 10
	ingressTraefikTest = "ingress-traefik-test"
)

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestIngressTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress traefik Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'ingress traefik' addon", Ordered, func() {
	AfterAll(func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "delete", "-k", "workloads")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())

		k2s.VerifyAddonIsDisabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", ingressTraefikTest)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux2", ingressTraefikTest)
	})

	It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "traefik")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

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
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})

	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})

	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().MustExec(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})

	It("prints already-enabled message and exits with non-zero", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable, with http status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through traefik ingress controller via ingress", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://k2s.cluster.local/albums-linux1")

		Expect(err).ToNot(HaveOccurred())
	})

	It("sample app is reachable through traefik ingress controller via svc", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux2", "ingress-traefik-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://albums-linux2.ingress-traefik-test.svc.cluster.local/albums-linux2")

		Expect(err).ToNot(HaveOccurred())
	})

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "traefik")

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The traefik ingress controller is working"),
			MatchRegexp("The external IP for traefik service is set to %s", regex.IpAddressRegex),
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
		))

		output = suite.K2sCli().MustExec(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

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
})
