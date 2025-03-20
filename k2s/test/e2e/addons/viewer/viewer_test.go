// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
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
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"

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

func TestViewer(t *testing.T) {
    RegisterFailHandler(Fail)
    RunSpecs(t, "viewer Addon Acceptance Tests", Label("addon", "addon-medical", "acceptance", "setup-required", "invasive", "viewer", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
    suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
    suite.TearDown(ctx)
})

var _ = Describe("'viewer' addon", Ordered, func() {
    Describe("status command", func() {
        Context("default output", func() {
            It("displays disabled message", func(ctx context.Context) {
                output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "viewer")

                Expect(output).To(SatisfyAll(
                    MatchRegexp(`ADDON STATUS`),
                    MatchRegexp(`Addon .+viewer.+ is .+disabled.+`),
                ))
            })
        })

        Context("JSON output", func() {
            It("displays JSON", func(ctx context.Context) {
                output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "viewer", "-o", "json")

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
                output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", "viewer")

                Expect(output).To(ContainSubstring("already disabled"))
            })
        })
    })

     Describe("enable command", func() {
        When("no ingress controller is configured", func() {
            AfterAll(func(ctx context.Context) {
                portForwardingSession.Kill()
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")

                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })

            It("is reachable through port forwarding", func(ctx context.Context) {
                kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
                portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
                portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

                // Using suite.HttpClient().Get instead of curl
                _, err := suite.HttpClient().Get(ctx, "http://localhost:8443/viewer/", &tls.Config{InsecureSkipVerify: true})
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
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "traefik", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
            })

            AfterAll(func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "traefik", "-o")

                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })

            It("is reachable through k2s.cluster.local", func(ctx context.Context) {
                url := "https://k2s.cluster.local/viewer/#/pod?namespace=_all"
                _, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
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
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
            })

            AfterAll(func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })

            It("is reachable through k2s.cluster.local", func(ctx context.Context) {
                url := "https://k2s.cluster.local/viewer/#/pod?namespace=_all"
                _, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
            })

            It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
                expectAddonToBeAlreadyEnabled(ctx)
            })

            It("prints the status", func(ctx context.Context) {
                expectStatusToBePrinted(ctx)
            })
        })

        When("Dicom addon and nginx ingress controller are active before viewer activation", func() {
            BeforeAll(func(ctx context.Context) {
                // enable dicom addon
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dicom", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

                //enable nginx ingress
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
                Expect(addonsStatus.IsAddonEnabled("ingress", "nginx")).To(BeTrue())
            })

            AfterAll(func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dicom", "-o", "-f")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("ingress", "nginx")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })

            It("retrieves patient data from the Dicom addon", func(ctx context.Context) {
                url := "https://k2s.cluster.local/viewer/datasources/config.json"
                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
                response := string(responseBytes)
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "dataFromDicomAddonTls"`))
                Expect(response).To(ContainSubstring(`"useSharedArrayBuffer": "TRUE"`))
            })

            It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
                expectAddonToBeAlreadyEnabled(ctx)
            })

            It("prints the status", func(ctx context.Context) {
                expectStatusToBePrinted(ctx)
            })
        })

        When("Dicom addon is not active before viewer activation only nginx ingress controller is, Dicom addon gets activated later", func() {
            BeforeAll(func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "ingress", "nginx", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
            })

            AfterAll(func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dicom", "-o", "-f")
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")

                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("ingress", "nginx")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })
            It("does NOT retrieve patient data from the Dicom addon", func(ctx context.Context) {
                url := "https://k2s.cluster.local/viewer/datasources/config.json"
                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
                response := string(responseBytes)

                // checking that the default datasource is DataFromAWS means that the patient data is NOT coming from the dicom addon
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
            })
            It("Dicom addon is enabled", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dicom", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
            })

            It("retrieves patient data from the Dicom addon", func(ctx context.Context) {
                url := "https://k2s.cluster.local/viewer/datasources/config.json"
                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
                response := string(responseBytes)
                // checking that the default datasource is dataFromDicomAddonTls
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "dataFromDicomAddonTls"`))
                Expect(response).To(ContainSubstring(`"useSharedArrayBuffer": "TRUE"`))
            })
            It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
                expectAddonToBeAlreadyEnabled(ctx)
            })

            It("prints the status", func(ctx context.Context) {
                expectStatusToBePrinted(ctx)
            })
        })

        When("Dicom addon is active but no ingress controller is configured", func() {
            BeforeAll(func(ctx context.Context) {
                // enable dicom addon
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dicom", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
            })
            AfterAll(func(ctx context.Context) {
                portForwardingSession.Kill()

                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")

                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dicom", "-o", "-f")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })

            It("retrieves patient data from AWS", func(ctx context.Context) {
                kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
                portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
                portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

                url := "http://localhost:8443/viewer/datasources/config.json"
                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
                response := string(responseBytes)
                // checking that the default datasource is DataFromAWS
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
            })

            It("prints already-enabled message when enabling the addon again and exits with non-zero", func(ctx context.Context) {
                expectAddonToBeAlreadyEnabled(ctx)
            })

            It("prints the status", func(ctx context.Context) {
                expectStatusToBePrinted(ctx)
            })
        })

        When("Neither Dicom addon nor any ingress controller is active before, Dicom addon gets activated later", func() {
            AfterAll(func(ctx context.Context) {
                portForwardingSession.Kill()
                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "viewer", "-o")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "viewerwebapp", "viewer")

                suite.K2sCli().RunOrFail(ctx, "addons", "disable", "dicom", "-o", "-f")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "postgres", "dicom")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeFalse())
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeFalse())
            })

            It("is in enabled state and pods are in running state", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "viewer", "-o")

                suite.Cluster().ExpectDeploymentToBeAvailable("viewerwebapp", "viewer")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "viewerwebapp", "viewer")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("viewer", "")).To(BeTrue())
            })
            It("does NOT retrieve patient data from the Dicom addon", func(ctx context.Context) {
                kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
                portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
                portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

                url := "http://localhost:8443/viewer/datasources/config.json"

                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())
                // Convert the response to a map
                var response = string(responseBytes)
                // checking that the default datasource is DataFromAWS means that the patient data is NOT coming from the dicom addon
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
                portForwardingSession.Kill()
            })
            It("Dicom addon is enabled", func(ctx context.Context) {
                suite.K2sCli().RunOrFail(ctx, "addons", "enable", "dicom", "-o")
                suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
                suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")

                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
                suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")

                addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
                Expect(addonsStatus.IsAddonEnabled("dicom", "")).To(BeTrue())
            })

            It("still retrieves patient data from AWS", func(ctx context.Context) {
                kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
                portForwarding := exec.Command(kubectl, "-n", "viewer", "port-forward", "svc/viewerwebapp", "8443:80")
                portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

                url := "http://localhost:8443/viewer/datasources/config.json"
                responseBytes, err := suite.HttpClient().Get(ctx, url, &tls.Config{InsecureSkipVerify: true})
                Expect(err).NotTo(HaveOccurred())

                response := string(responseBytes)
                // checking that the default datasource is still DataFromAWS
                Expect(response).To(ContainSubstring(`"defaultDataSourceName": "DataFromAWS"`))
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
    output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "viewer")

    Expect(output).To(ContainSubstring("already enabled"))
}

func expectStatusToBePrinted(ctx context.Context) {
    output := suite.K2sCli().RunOrFail(ctx, "addons", "status", "viewer")

    Expect(output).To(SatisfyAll(
        MatchRegexp("ADDON STATUS"),
        MatchRegexp(`Addon .+viewer.+ is .+enabled.+`),
        MatchRegexp("The viewer is working"),
    ))

    output = suite.K2sCli().RunOrFail(ctx, "addons", "status", "viewer", "-o", "json")

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
