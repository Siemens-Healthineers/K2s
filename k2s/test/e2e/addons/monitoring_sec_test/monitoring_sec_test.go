package monitoring_sec

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

var (
	suite *framework.K2sTestSuite
)

func TestMonitoringSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "monitoring Addon Acceptance Tests", Label("addon", "addon-security-enhanced-2", "acceptance", "setup-required", "invasive", "monitoring", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	// Disable the monitoring, security and ingress nginx addons after all tests
	suite.K2sCli().RunOrFail(ctx, "addons", "disable", "monitoring", "-o")
	suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
	suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
	suite.TearDown(ctx)
})

var _ = Describe("'monitoring and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then monitoring addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "monitoring", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeTrue())
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().RunOrFail(ctx, "addons", "disable", "security", "-o")
		})
	})

	Describe("Monitoring addon activated first then security addon", func() {
		It("activates the monitoring addon", func(ctx context.Context) {
			suite.K2sCli().RunOrFail(ctx, "addons", "enable", "monitoring", "-o")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			if suite.Proxy() != "" {
				args = append(args, "-p", suite.Proxy())
			}
			suite.K2sCli().RunOrFail(ctx, args...)
			time.Sleep(30 * time.Second)
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-plutono", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-plutono", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "monitoring")

			addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
			Expect(addonsStatus.IsAddonEnabled("monitoring", "")).To(BeTrue())
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
		})

	})

})