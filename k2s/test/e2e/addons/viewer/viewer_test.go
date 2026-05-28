// SPDX-FileCopyrightText: © 2026 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package viewer

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gexec"
	"github.com/onsi/gomega/gstruct"
)

const testClusterTimeout = time.Minute * 15

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	k2s                   *dsl.K2s
	testFailed            = false
)

func TestViewer(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "viewer Addon Acceptance Tests", Label("addon", "addon-medical", "acceptance", "setup-required", "invasive", "viewer", "system-running"))
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

var _ = Describe("'viewer' addon", Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "viewer")

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+viewer.+ is .+disabled.+`),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().MustExec(ctx, "addons", "status", "viewer", "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal("viewer"))
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
				output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "viewer")

				Expect(output).To(ContainSubstring("already disabled"))
			})
		})
	})

	Describe("enable command", func() {
		When("no ingress controller is configured", func() {
			AfterAll(func(ctx context.Context) {
				portForwardingSession.Kill()
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")

				k2s.VerifyAddonIsDisabled("viewer")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
			})

			It("is in enabled state and pods are in running state", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")

				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")
			})

			It("is reachable through port forwarding", func(ctx context.Context) {
				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, "http://localhost:8443/viewer/")
				Expect(err).NotTo(HaveOccurred())
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
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

				k2s.VerifyAddonIsDisabled("viewer")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			})

			It("is in enabled state and reachable through k2s.cluster.local", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				url := "https://k2s.cluster.local/viewer/#/pod?namespace=_all"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})
		})

		When("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

				k2s.VerifyAddonIsDisabled("viewer")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
			})

			It("is in enabled state and reachable through k2s.cluster.local", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				url := "https://k2s.cluster.local/viewer/#/pod?namespace=_all"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})
		})

		When("nginx-gw as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")

				k2s.VerifyAddonIsDisabled("viewer")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "nginx-gw", "nginx-gw")
			})

			It("is in enabled state and reachable through k2s.cluster.local", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "--ingress", "nginx-gw", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				url := "https://k2s.cluster.local/viewer/#/pod?namespace=_all"
				_, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
			})
		})

		When("Dicom integration with nginx ingress", func() {
			BeforeAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

				k2s.VerifyAddonIsDisabled("viewer")
				k2s.VerifyAddonIsDisabled("dicom")
				k2s.VerifyAddonIsDisabled("ingress", "nginx")
			})

			It("viewer without Dicom retrieves AWS data", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				url := "https://k2s.cluster.local/viewer/datasources/config.json"
				responseBytes, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
				response := string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
			})

			It("viewer retrieves Dicom data after Dicom addon is enabled", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

				url := "https://k2s.cluster.local/viewer/datasources/config.json"
				responseBytes, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
				response := string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "dataFromDicomAddonTls"`))
				Expect(response).To(ContainSubstring(`"useSharedArrayBuffer": "TRUE"`))
			})

			It("viewer retrieves Dicom data when Dicom is active before viewer activation", func(ctx context.Context) {
				// Dicom is still enabled from previous spec; disable viewer and re-enable
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")

				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				url := "https://k2s.cluster.local/viewer/datasources/config.json"
				responseBytes, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
				response := string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "dataFromDicomAddonTls"`))
				Expect(response).To(ContainSubstring(`"useSharedArrayBuffer": "TRUE"`))
			})
		})

		When("Dicom integration without ingress controller", func() {
			AfterAll(func(ctx context.Context) {
				if portForwardingSession != nil {
					portForwardingSession.Kill()
				}

				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

				k2s.VerifyAddonIsDisabled("viewer")
				k2s.VerifyAddonIsDisabled("dicom")
			})

			It("viewer with active Dicom but no ingress retrieves AWS data via port forwarding", func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				url := "http://localhost:8443/viewer/datasources/config.json"
				responseBytes, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())
				response := string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
				portForwardingSession.Kill()
			})

			It("viewer without Dicom retrieves AWS data and still retrieves AWS after Dicom is enabled later", func(ctx context.Context) {
				// Disable both from the previous spec
				suite.K2sCli().MustExec(ctx, "addons", "disable", "viewer", "-o")
				suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")

				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")

				// Enable viewer first (no dicom, no ingress)
				suite.K2sCli().MustExec(ctx, "addons", "enable", "viewer", "-o")

				k2s.VerifyAddonIsEnabled("viewer")

				suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

				kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
				portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				url := "http://localhost:8443/viewer/datasources/config.json"
				responseBytes, err := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())

				response := string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
				portForwardingSession.Kill()

				// Now enable dicom — viewer should still serve AWS data (no ingress)
				suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

				k2s.VerifyAddonIsEnabled("dicom")

				suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
				suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

				portForwarding = exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
				portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

				responseBytes, err = suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, url)
				Expect(err).NotTo(HaveOccurred())

				response = string(responseBytes)
				Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
			})
		})
	})
})

func expectAddonToBeAlreadyEnabled(ctx context.Context) {
	output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "viewer")

	Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "viewer")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+viewer.+ is .+enabled.+`),
		MatchRegexp("The viewer is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "viewer", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("viewer"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "IsViewerRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("The viewer is working")))),
	))
}
