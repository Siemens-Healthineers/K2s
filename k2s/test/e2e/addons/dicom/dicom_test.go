// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package dicom

import (
	"context"
	"encoding/json"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 10

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
)

func TestDicom(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dicom Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "dicom", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("'dicom' addon", Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "dicom")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+dicom.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", "dicom", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("dicom"))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		When("addon is already disabled", func() {
			It("prints already-disabled message and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", "dicom")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	Describe("enable command", func() {
		When("no ingress controller is configured", func() {
			AfterAll(func(ctx context.Context) {
				portForwardingSession.Kill()
				suite.K2sCli().Run(ctx, "addons", "disable", "dicom", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "mysql", "dicom")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "dicom", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("mysql", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "mysql", "dicom")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
			})

			It("is reachable through port forwarding", func(ctx context.Context) {
				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "dicom", "port-forward", "svc/dicom", "8042:8042")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				url := "http://localhost:8042"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", "-o", "/dev/null", "-w", "%{http_code}", "-L", url, "-k", "-m", "5", "--retry", "10", "--fail")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("traefik as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "dicom", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "traefik", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "mysql", "dicom")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "dicom", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("mysql", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "mysql", "dicom")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "https://k2s.cluster.local/dicom/ui/app"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", "-o", "/dev/null", "-w", "%{http_code}", "-L", url, "-k", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})

		When("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "disable", "dicom", "-o")
				suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "mysql", "dicom")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "addons", "enable", "dicom", "-o")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("mysql", "dicom")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "mysql", "dicom")

				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
			})

			It("is reachable through k2s.cluster.local", func(ctx context.Context) {
				url := "http://k2s.cluster.local/dicom/ui/app"
				httpStatus := suite.Cli().ExecOrFail(ctx, "curl.exe", "-o", "/dev/null", "-w", "%{http_code}", "-L", url, "-k", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				Expect(httpStatus).To(ContainSubstring("200"))
			})

			It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
				expectAddonToBeAlreadyEnabled(ctx)
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", "dicom")

	Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", "dicom")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+dicom.+ is .+enabled.+`),
		MatchRegexp("The dicom Deployment is working"),
		MatchRegexp("The mysql Deployment is working"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", "dicom", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("dicom"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "dicom"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The dicom Deployment is working"))),
		),
		SatisfyAll(
			HaveField("Name", "mysql"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The mysql Deployment is working"))),
		),
	))
}
