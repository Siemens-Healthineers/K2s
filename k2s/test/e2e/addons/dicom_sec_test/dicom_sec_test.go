// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dicom_sec

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 10

var suite *framework.K2sTestSuite

func TestDicomSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dicom Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dicom", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")

	suite.TearDown(ctx)
})

var _ = Describe("'dicom and security enhanced' addons", Ordered, func() {
	Describe("Security addon activated first then dicom addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().MustExec(ctx, args...)

			time.Sleep(30 * time.Second)
		})

		It("activates the dicom addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
			suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dicom")
		})

		It("tests connectivity to the dicom server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/ui/app"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dicom", "-o", "-f")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Dicom addon activated first then security addon", func() {
		It("activates the dicom addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dicom", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("dicom", "dicom")
			suite.Cluster().ExpectDeploymentToBeAvailable("postgres", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "orthanc", "dicom")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", "postgres", "dicom")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dicom")
		})

		It("tests connectivity to the dicom server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/dicom/ui/app"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})
	})
})
