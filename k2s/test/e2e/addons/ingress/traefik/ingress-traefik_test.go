// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package traefik

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

const ingressTraefikTest = "ingress-traefik-test"

func TestIngressTraefik(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress traefik Addon Acceptance Tests", Label("addon", "addon-communication", "acceptance", "setup-required", "invasive", "ingress-traefik", "system-running"))
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
		suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux1", ingressTraefikTest)
		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "albums-linux2", ingressTraefikTest)

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", "traefik")).To(BeFalse())
	})

	It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already disabled"))
	})

	Describe("status", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", "traefik")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

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
		suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

		addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
		Expect(addonsStatus.IsAddonEnabled("ingress", "traefik")).To(BeTrue())
	})

	It("prints already-enabled message and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "ingress", "traefik")

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("makes k2s.cluster.local reachable, with http status NotFound", func(ctx context.Context) {
		url := "https://k2s.cluster.local/"
		httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", url, "-k", "-I", "-m", "5", "--retry", "10")
		Expect(httpStatus).To(ContainSubstring("404"))
	})

	It("sample app is reachable through traefik ingress controller via ingress", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux1", "ingress-traefik-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://k2s.cluster.local/albums-linux1")

		Expect(err).ToNot(HaveOccurred())
	})

	It("sample app is reachable through traefik ingress controller via svc", func(ctx context.Context) {
		suite.Kubectl().Run(ctx, "apply", "-k", "workloads")
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "albums-linux2", "ingress-traefik-test")

		_, err := suite.HttpClient().GetJson(ctx, "http://albums-linux2.ingress-traefik-test.svc.cluster.local/albums-linux2")

		Expect(err).ToNot(HaveOccurred())
	})

	It("prints the status", func(ctx context.Context) {
		output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", "traefik")

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Implementation .+traefik.+ of Addon .+ingress.+ is .+enabled.+`),
			MatchRegexp("The traefik ingress controller is working"),
			MatchRegexp("The external IP for traefik service is set to %s", regex.IpAddressRegex),
		))

		output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "ingress", "traefik", "-o", "json")

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
