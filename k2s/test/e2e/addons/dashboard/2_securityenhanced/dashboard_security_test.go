// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dashboardsecurity

import (
	"context"
	"os/exec"
	"path"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
)

func TestDashboardSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Dashboard and Security (Enhanced) Addon Acceptance Tests", Label("addon", "addon-security-enhanced-1", "acceptance", "setup-required", "invasive", "dashboard", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: BeforeSuite - Setting up dashboard security test")
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)
	GinkgoWriter.Println(">>> TEST: BeforeSuite complete")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println(">>> TEST: AfterSuite - Cleaning up dashboard security test")

	// Guard against BeforeSuite failure: if suite was never initialised (e.g. addons
	// were still enabled when the test started), skip cleanup to avoid a nil-pointer panic.
	if suite == nil {
		GinkgoWriter.Println(">>> TEST: AfterSuite - suite is nil (BeforeSuite failed), skipping cleanup")
		return
	}

	if testFailed {
		// Best-effort diagnostic dump — must NOT block AfterSuite.
		// Use os/exec directly with a 3-minute context so MSINFO32 or other
		// slow host-diag tools can't hang the suite indefinitely.
		GinkgoWriter.Println(">>> TEST: AfterSuite - collecting system dump (best-effort, 3 min cap)")
		dumpCtx, dumpCancel := context.WithTimeout(context.Background(), 3*time.Minute)
		defer dumpCancel()
		k2sExe := path.Join(suite.RootDir(), "k2s.exe")
		dumpCmd := exec.CommandContext(dumpCtx, k2sExe, "system", "dump", "-S", "-o")
		if out, err := dumpCmd.CombinedOutput(); err != nil {
			GinkgoWriter.Printf(">>> TEST: AfterSuite - system dump error: %v (output: %s)\n", err, string(out))
		}
	}

	// Always attempt addon cleanup — best-effort, regardless of testFailed.
	// Individual Describe blocks have their own deactivation It steps; these
	// guards ensure we clean up even if a test fails mid-scenario.
	suite.SetupInfo().ReloadRuntimeConfig()

	if k2s.IsAddonEnabled("dashboard") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover dashboard addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
	}
	if k2s.IsAddonEnabled("ingress", "nginx") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover ingress nginx addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}
	if k2s.IsAddonEnabled("security") {
		GinkgoWriter.Println(">>> TEST: AfterSuite - disabling leftover security addon")
		suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
	}

	suite.TearDown(ctx)
	GinkgoWriter.Println(">>> TEST: AfterSuite complete")
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("'dashboard and security enhanced' addons", Ordered, func() {

	Describe("Security addon activated first then dashboard addon", func() {
		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			GinkgoWriter.Println(">>> TEST: Security addon enabled")
		})

		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Dashboard addon (Headlamp) enabled and verified with linkerd injection")
		})

		It("deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})

	Describe("Dashboard addon activated first then security addon", func() {
		It("activates the dashboard addon", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling dashboard addon first")
			suite.K2sCli().MustExec(ctx, "addons", "enable", "dashboard", "-o")

			suite.Cluster().ExpectDeploymentToBeAvailable("headlamp", "dashboard")
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app.kubernetes.io/name", "headlamp", "dashboard")
			GinkgoWriter.Println(">>> TEST: Dashboard addon (Headlamp) enabled")
		})

		It("activates the security addon in enhanced mode", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Enabling security addon in enhanced mode")
			args := []string{"addons", "enable", "security", "-t", "enhanced", "-o"}
			suite.K2sCli().MustExec(ctx, args...)
			time.Sleep(30 * time.Second)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "linkerd.io/control-plane-ns", "linkerd", "dashboard")
			GinkgoWriter.Println(">>> TEST: Security addon enabled and linkerd injection verified")
		})

		It("deactivates all the addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: Deactivating all addons")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "dashboard", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
			suite.K2sCli().MustExec(ctx, "addons", "disable", "security", "-o")
			GinkgoWriter.Println(">>> TEST: All addons deactivated")
		})
	})
})
