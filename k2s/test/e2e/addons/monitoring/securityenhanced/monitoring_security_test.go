// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package monitoringsecurity

import (
	"context"
	"fmt"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"
	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Per-spec timeout. Each It in this suite triggers either a full security-enhanced
// enable (linkerd install + cert-manager + trust-manager + keycloak + kyverno) or a
// security re-enable on top of an already-running monitoring stack which then rolls
// 5 monitoring deployments + ingress with linkerd injection. The "Deactivates all
// addons" step disables security which tears down linkerd/kyverno/cert-manager —
// namespace deletion alone can take 45 min on resource-constrained CI nodes.
// 50 min gives headroom for the worst-case teardown path.
const testClusterTimeout = time.Minute * 50

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestMonitoringSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Monitoring and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-3", "acceptance", "setup-required", "invasive", "monitoring", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up monitoring security test")
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up monitoring security test")

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

// ensureMonitoringIngressApplied works around the production code's limited retry
// count in Update-IngressForNginx (3 attempts / 10s delay). If the ingress nginx
// admission webhook was down when Update.ps1 ran, the monitoring ingress resource
// may not exist — causing a persistent 404. This function checks for the ingress
// resource and re-applies the appropriate manifest (secure variant when keycloak is
// present) with generous retries.
func ensureMonitoringIngressApplied(ingressType string) {
	rootDir, err := sos.RootDir()
	Expect(err).NotTo(HaveOccurred(), "Failed to get root dir")

	kubectlPath := filepath.Join(rootDir, "bin", "kube", "kubectl.exe")

	// Determine the right ingress resource name and manifest directory
	var ingressName, manifestDir string
	switch ingressType {
	case "nginx":
		ingressName = "monitoring-nginx-cluster-local"
		// Use secure variant if keycloak is present
		secureDir := filepath.Join(rootDir, "addons", "monitoring", "manifests", "ingress-nginx-secure")
		standardDir := filepath.Join(rootDir, "addons", "monitoring", "manifests", "ingress-nginx")
		// Check if keycloak is running
		out, err := exec.Command(kubectlPath, "get", "service", "-n", "security", "-o", "yaml").CombinedOutput()
		if err == nil && strings.Contains(string(out), "keycloak") {
			manifestDir = secureDir
		} else {
			manifestDir = standardDir
		}
	case "nginx-gw":
		ingressName = "monitoring-nginx-gw-https"
		secureDir := filepath.Join(rootDir, "addons", "monitoring", "manifests", "ingress-nginx-gw-secure")
		standardDir := filepath.Join(rootDir, "addons", "monitoring", "manifests", "ingress-nginx-gw")
		out, err := exec.Command(kubectlPath, "get", "service", "-n", "security", "-o", "yaml").CombinedOutput()
		if err == nil && strings.Contains(string(out), "keycloak") {
			manifestDir = secureDir
		} else {
			manifestDir = standardDir
		}
	default:
		Fail(fmt.Sprintf("Unknown ingress type: %s", ingressType))
	}

	// Check if the monitoring ingress resource already exists
	// For nginx-gw, check HTTPRoute instead of Ingress
	var resourceType string
	if ingressType == "nginx-gw" {
		resourceType = "httproute"
	} else {
		resourceType = "ingress"
	}
	out, err := exec.Command(kubectlPath, "get", resourceType, ingressName, "-n", "monitoring", "--ignore-not-found", "-o", "name").CombinedOutput()
	if err == nil && strings.TrimSpace(string(out)) != "" {
		GinkgoWriter.Printf(">>> TEST: Monitoring ingress '%s' already exists, no re-apply needed\n", ingressName)
		return
	}

	// Ingress doesn't exist — re-apply with retries
	GinkgoWriter.Printf(">>> TEST: Monitoring ingress '%s' NOT found — re-applying from %s\n", ingressName, manifestDir)
	maxRetries := 10
	retryDelay := 15 * time.Second
	for attempt := 1; attempt <= maxRetries; attempt++ {
		out, err := exec.Command(kubectlPath, "apply", "-k", manifestDir).CombinedOutput()
		if err == nil {
			GinkgoWriter.Printf(">>> TEST: Successfully re-applied monitoring ingress on attempt %d/%d\n", attempt, maxRetries)
			// Give nginx a moment to reload
			time.Sleep(5 * time.Second)
			return
		}
		GinkgoWriter.Printf(">>> TEST: Ingress apply attempt %d/%d failed: %s\n", attempt, maxRetries, string(out))
		if attempt < maxRetries {
			time.Sleep(retryDelay)
		}
	}
	Fail(fmt.Sprintf("Failed to apply monitoring ingress after %d attempts", maxRetries))
}

var _ = Describe("'monitoring and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then monitoring addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			// Security enhanced installs linkerd which triggers injection / rolling
			// restarts across the cluster. Wait for the cluster to stabilize before
			// proceeding so that subsequent addon enables don't collide with ongoing
			// restarts or webhook unavailability.
			GinkgoWriter.Println(">>> TEST: Waiting 60s for cluster stabilization after security enable")
			time.Sleep(60 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})


		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--ingress", "nginx", "-o")
			// After enabling monitoring with security active, Update.ps1 patches
			// monitoring deployments with linkerd injection and applies ingress
			// manifests. Pod restarts + webhook recovery may take minutes.
			GinkgoWriter.Println(">>> TEST: Waiting 60s for monitoring pods to stabilize after linkerd injection")
			time.Sleep(60 * time.Second)

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled and verified")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server")
			// Ensure monitoring ingress exists — Update.ps1's 3-retry apply may have
			// failed if the admission webhook was down during monitoring enable.
			ensureMonitoringIngressApplied("nginx")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})


	Describe("Monitoring addon activated first then security addon", func() {
		It("activates the ingress addon with nginx", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress addon with nginx")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			GinkgoWriter.Println(">>> TEST: Ingress nginx addon enabled")
		})

		It("activates the monitoring addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--ingress", "nginx", "-o")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			// When security is enabled after monitoring, Update.ps1 patches monitoring
			// deployments with linkerd injection, causing rolling restarts. The ingress
			// controller also restarts and its admission webhook may be unavailable for
			// several minutes. Wait generously for everything to settle.
			GinkgoWriter.Println(">>> TEST: Waiting 120s for cluster stabilization after security enable (monitoring already running)")
			time.Sleep(120 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Verifying monitoring addon state")
			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon verified")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server")
			ensureMonitoringIngressApplied("nginx")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Security addon activated first then monitoring addon with nginx-gw ingress", func() {
		It("activates the ingress addon with nginx-gw", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling ingress addon with nginx-gw")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
			suite.Cluster().ExpectDeploymentToBeAvailable("nginx-gw-controller", "nginx-gw")
			GinkgoWriter.Println(">>> TEST: Ingress nginx-gw addon enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			GinkgoWriter.Println(">>> TEST: Waiting 60s for cluster stabilization after security enable")
			time.Sleep(60 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("is in enabled state and pods are in running state", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling monitoring addon with nginx-gw ingress")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "monitoring", "--ingress", "nginx-gw", "-o")
			// Same stabilization wait as nginx scenario
			GinkgoWriter.Println(">>> TEST: Waiting 60s for monitoring pods to stabilize after linkerd injection")
			time.Sleep(60 * time.Second)

			k2s.VerifyAddonIsEnabled("monitoring")

			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectDeploymentToBeAvailable("kube-prometheus-stack-grafana", "monitoring")

			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-kube-state-metrics", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "kube-prometheus-stack-operator", "monitoring")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "grafana", "monitoring")
			GinkgoWriter.Println(">>> TEST: Monitoring addon enabled and verified")
		})

		It("tests connectivity to the monitoring server using bearer token", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Testing connectivity to monitoring server via nginx-gw")
			ensureMonitoringIngressApplied("nginx-gw")
			token, err := addons.GetKeycloakToken()
			Expect(err).NotTo(HaveOccurred(), "Failed to retrieve keycloak token")
			headers := map[string]string{
				"Authorization": fmt.Sprintf("Bearer %s", token),
			}
			url := "https://k2s.cluster.local/monitoring/login"
			addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusOK, url, headers)
			GinkgoWriter.Println(">>> TEST: Monitoring server connectivity verified via nginx-gw")
		})

		It("Deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "monitoring", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

})
