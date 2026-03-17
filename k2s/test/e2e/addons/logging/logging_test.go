// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package logging

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"path"
	"strings"
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

const testClusterTimeout = time.Minute * 20

var (
	suite                 *framework.K2sTestSuite
	portForwardingSession *gexec.Session
	linuxOnly             = false
	k2s                   *dsl.K2s
	testFailed            = false
)

func TestLogging(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "logging Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "logging", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
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

var _ = Describe("'logging' addon", Ordered, func() {
	// Phase 1: Tests while logging addon is disabled (before enabling)
	Describe("disabled state", func() {
		It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "disable", "logging")

			Expect(output).To(ContainSubstring("already disabled"))
		})

		Describe("status", func() {
			Context("default output", func() {
				It("displays disabled message", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging")

					Expect(output).To(SatisfyAll(
						MatchRegexp(`ADDON STATUS`),
						MatchRegexp(`Addon .+logging.+ is .+disabled.+`),
					))
				})
			})

			Context("JSON output", func() {
				It("displays JSON", func(ctx context.Context) {
					output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging", "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Name).To(Equal("logging"))
					Expect(status.Enabled).NotTo(BeNil())
					Expect(*status.Enabled).To(BeFalse())
					Expect(status.Props).To(BeNil())
					Expect(status.Error).To(BeNil())
				})
			})
		})
	})

	// Phase 2: Enable logging once, then run all enabled-state tests and ingress variants
	Describe("enabled state", Ordered, func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "logging", "-o")

			k2s.VerifyAddonIsEnabled("logging")

			expectLoggingPodsReady(ctx)
		})

		AfterAll(func(ctx context.Context) {
			if portForwardingSession != nil {
				portForwardingSession.Kill()
			}

			suite.K2sCli().MustExec(ctx, "addons", "disable", "logging", "-o")

			k2s.VerifyAddonIsDisabled("logging")

			expectLoggingResourcesRemoved(ctx)
		})

		// Phase 2a: Core enabled-state tests (no ingress needed)
		It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "enable", "logging")

			Expect(output).To(ContainSubstring("already enabled"))
		})

		It("prints the status", func(ctx context.Context) {
			expectStatusToBePrinted(ctx)
		})

		It("is reachable through port forwarding", func(ctx context.Context) {
			kubectl := path.Join(suite.RootDir(), "bin", "kube", "kubectl.exe")
			portForwarding := exec.Command(kubectl, "-n", "logging", "port-forward", "svc/opensearch-dashboards", "5601:5601")
			portForwardingSession, _ = gexec.Start(portForwarding, GinkgoWriter, GinkgoWriter)

			url := "http://localhost:5601/logging"
			httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-D", "-", "-o", "NUL", "-m", "5", "--retry", "10", "--retry-all-errors")
			Expect(httpStatus).To(ContainSubstring("302"))
			Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
		})

		// Phase 2b: Ingress reachability tests (logging stays enabled, only ingress toggles)
		When("traefik as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				if portForwardingSession != nil {
					portForwardingSession.Kill()
				}

				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
			})

			It("is reachable through k2s.cluster.local/logging", func(ctx context.Context) {
				url := "https://k2s.cluster.local/logging"
				httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-D", "-", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				// we expect a re-direct to /logging/app/home
				Expect(httpStatus).To(ContainSubstring("302"))
				Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
			})
		})

		Describe("nginx as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				waitForNamespaceTermination(ctx, "cert-manager")

				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("ingress-nginx-controller", "ingress-nginx")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "ingress-nginx", "ingress-nginx")
			})

			It("is reachable through k2s.cluster.local/logging", func(ctx context.Context) {
				url := "https://k2s.cluster.local/logging"
				httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-v", "-D", "-", "-o", "NUL", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				// we expect a re-direct to /logging/app/home
				Expect(httpStatus).To(ContainSubstring("302"))
				Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
			})
		})

		Describe("nginx-gw as ingress controller", func() {
			BeforeAll(func(ctx context.Context) {
				waitForNamespaceTermination(ctx, "cert-manager")

				suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeAvailable("nginx-cluster-local-nginx-gw", "nginx-gw")
			})

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx-gw", "-o")
				suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app", "nginx-gw-controller", "nginx-gw")
			})

			It("is reachable through k2s.cluster.local/logging", func(ctx context.Context) {
				url := "https://k2s.cluster.local/logging"
				httpStatus := suite.Cli("curl.exe").MustExec(ctx, url, "-k", "-I", "-m", "5", "--retry", "10", "--fail", "--retry-all-errors")
				// we expect a re-direct to /logging/app/home
				Expect(httpStatus).To(ContainSubstring("302"))
				Expect(httpStatus).To(ContainSubstring("/logging/app/home"))
			})
		})
	})
})

// waitForNamespaceTermination polls until the given namespace no longer exists.
// If the namespace is stuck in Terminating state (e.g. because cert-manager CRD
// controllers were deleted before their resources' finalizers could be processed),
// it forcefully removes finalizers to unblock the deletion.
func waitForNamespaceTermination(ctx context.Context, ns string) {
	_, exitCode := suite.Kubectl().Exec(ctx, "get", "namespace", ns)
	if exitCode != 0 {
		return // already gone
	}

	Eventually(func() bool {
		phase, code := suite.Kubectl().Exec(ctx, "get", "namespace", ns,
			"-o", "jsonpath={.status.phase}")
		if code != 0 {
			return true // namespace gone
		}
		if strings.TrimSpace(phase) == "Terminating" {
			forceCleanTerminatingNamespace(ctx, ns)
		}
		return false
	}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(BeTrue(),
		fmt.Sprintf("namespace %q should be fully terminated before proceeding", ns))
}

func forceCleanTerminatingNamespace(ctx context.Context, ns string) {
	GinkgoWriter.Printf("Namespace %q stuck in Terminating state \u2013 forcing cleanup\n", ns)

	apiResources, exitCode := suite.Kubectl().Exec(ctx, "api-resources",
		"--namespaced", "--verbs=list", "-o", "name")
	if exitCode == 0 {
		for _, rt := range strings.Split(apiResources, "\n") {
			rt = strings.TrimSpace(rt)
			if rt == "" || rt == "events" || rt == "events.events.k8s.io" {
				continue
			}
			suite.Kubectl().Exec(ctx, "patch", rt, "--all", "-n", ns,
				"--type=merge", "-p", `{"metadata":{"finalizers":null}}`)
		}
	}
}

func expectLoggingPodsReady(ctx context.Context) {
	suite.Cluster().ExpectDeploymentToBeAvailable("opensearch-dashboards", "logging")
	suite.Cluster().ExpectStatefulSetToBeReady("opensearch-cluster-master", "logging", 1, ctx)
	suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit", "logging", 1, ctx)
	if !linuxOnly {
		suite.Cluster().ExpectDaemonSetToBeReady("fluent-bit-win", "logging", 1, ctx)
	}

	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch", "logging")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit", "logging")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "fluent-bit-win", "logging")
	suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
}

func expectLoggingResourcesRemoved(ctx context.Context) {
	suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "opensearch-dashboards", "logging")
	suite.Cluster().ExpectStatefulSetToBeDeleted("opensearch-cluster-master", "logging", ctx)
	suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit", "logging", ctx)
	if !linuxOnly {
		suite.Cluster().ExpectDaemonSetToBeDeleted("fluent-bit-win", "logging", ctx)
	}
}

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", "logging")

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+logging.+ is .+enabled.+`),
		MatchRegexp("Opensearch dashboards are working"),
		MatchRegexp("Opensearch is working"),
		MatchRegexp("Fluent-bit is working"),
	))

	output = suite.K2sCli().MustExec(ctx, "addons", "status", "logging", "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal("logging"))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "AreDeploymentsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("Opensearch dashboards are working")))),
		SatisfyAll(
			HaveField("Name", "AreStatefulsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Opensearch is working")))),
		SatisfyAll(
			HaveField("Name", "AreDaemonsetsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(MatchRegexp("Fluent-bit is working")))),
	))
}
