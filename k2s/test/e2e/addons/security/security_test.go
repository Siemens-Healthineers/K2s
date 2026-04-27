// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// DIAGNOSTIC BUILD: This is a temporary test file to isolate the root cause
// of the albums-win1 403→200 regression. It tests 4 combinations:
//   1. No Kyverno + No probes  (baseline)
//   2. No Kyverno + With probes
//   3. Kyverno    + No probes
//   4. Kyverno    + With probes (known failure)
//
// Remove this file and restore the original after the diagnostic CI run.

package security

import (
	"context"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/addons"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const addonName = "security"
const namespace = "k2s"

var linuxDeploymentNames = []string{"albums-linux1", "albums-linux2", "albums-linux3"}
var winDeploymentNames = []string{"albums-win1", "albums-win2", "albums-win3"}

// manifestDir is set per-cycle to switch between workload overlays
var manifestDir string

var testFailed = false
var workloadCreated = false
var suite *framework.K2sTestSuite
var testStepTimeout = time.Minute * 20

func TestSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Diagnostic Tests", Label("addon", "addon-security", "acceptance", "setup-required", "invasive", "security", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testStepTimeout))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.StatusChecker().IsK2sRunning(ctx)

	GinkgoWriter.Println("Cleaning up workloads if necessary..")
	deleteWorkloadsIfNeeded(ctx)

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	isEnabled := func(name string, implementation ...string) bool {
		impl := ""
		if len(implementation) > 0 {
			impl = implementation[0]
		}
		return lo.ContainsBy(suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons(), func(a config.Addon) bool {
			return a.Name == name && a.Implementation == impl
		})
	}

	if isEnabled(addonName) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
	}

	if isEnabled("ingress", "nginx") {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func deployWorkloadsFromDir(ctx context.Context, dir string) {
	manifestDir = dir
	GinkgoWriter.Printf("Deploying workloads from %s\n", dir)

	suite.Kubectl().MustExec(ctx, "apply", "-k", dir)

	GinkgoWriter.Printf("Waiting for Deployments to be ready in namespace %s\n", namespace)
	suite.Kubectl().MustExec(ctx, "rollout", "status", "deployment", "-n", namespace, "--timeout="+suite.TestStepTimeout().String())

	for _, name := range linuxDeploymentNames {
		suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
		suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", name, namespace)
	}

	if !suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		for _, name := range winDeploymentNames {
			suite.Cluster().ExpectDeploymentToBeAvailable(name, namespace)
			suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", name, namespace)
		}
	}
	workloadCreated = true
	GinkgoWriter.Println("Deployments ready for testing")
}

func deleteWorkloadsIfNeeded(ctx context.Context) {
	if manifestDir != "" && workloadCreated {
		suite.Kubectl().MustExec(ctx, "delete", "-k", manifestDir)
		workloadCreated = false
		GinkgoWriter.Println("Workloads deleted")
	}
}

// checkWin1Forbidden verifies albums-win1 returns 403 from the host
func checkWin1Forbidden(ctx context.Context) {
	if suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly() {
		Skip("Linux-only setup, skipping Windows check")
	}
	url := fmt.Sprintf("http://albums-win1.%s.svc.cluster.local/albums-win1", namespace)
	addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusForbidden, url)
}

// checkLinux1Forbidden verifies albums-linux1 returns 403 from the host (control)
func checkLinux1Forbidden(ctx context.Context) {
	url := fmt.Sprintf("http://albums-linux1.%s.svc.cluster.local/albums-linux1", namespace)
	addons.VerifyDeploymentReachableFromHostWithStatusCode(ctx, http.StatusForbidden, url)
}

// --- Diagnostic Cycle 1: No Kyverno + No Probes (baseline, should match main branch) ---
var _ = Describe("Diagnostic 1: No Kyverno + No Probes", Ordered, Label("diag-1"), func() {
	It("enables security enhanced WITHOUT Kyverno", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "--omitPolicyEnf", "-o")
	})

	It("deploys workloads WITHOUT probes", func(ctx context.Context) {
		deployWorkloadsFromDir(ctx, "workload/windows-noprobes")
	})

	It("albums-linux1 returns 403 (control)", func(ctx context.Context) {
		checkLinux1Forbidden(ctx)
	})

	It("albums-win1 returns 403 (BASELINE)", func(ctx context.Context) {
		checkWin1Forbidden(ctx)
	})

	It("cleans up workloads", func(ctx context.Context) {
		deleteWorkloadsIfNeeded(ctx)
	})

	It("disables security", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables ingress", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})
})

// --- Diagnostic Cycle 2: No Kyverno + With Probes (isolates probe effect) ---
var _ = Describe("Diagnostic 2: No Kyverno + With Probes", Ordered, Label("diag-2"), func() {
	It("enables security enhanced WITHOUT Kyverno", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "--omitPolicyEnf", "-o")
	})

	It("deploys workloads WITH probes", func(ctx context.Context) {
		deployWorkloadsFromDir(ctx, "workload/windows")
	})

	It("albums-linux1 returns 403 (control)", func(ctx context.Context) {
		checkLinux1Forbidden(ctx)
	})

	It("albums-win1 returns 403 (probe isolation)", func(ctx context.Context) {
		checkWin1Forbidden(ctx)
	})

	It("cleans up workloads", func(ctx context.Context) {
		deleteWorkloadsIfNeeded(ctx)
	})

	It("disables security", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables ingress", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})
})

// --- Diagnostic Cycle 3: Kyverno + No Probes (isolates Kyverno effect) ---
var _ = Describe("Diagnostic 3: Kyverno + No Probes", Ordered, Label("diag-3"), func() {
	It("enables security enhanced WITH Kyverno", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "-o")
	})

	It("deploys workloads WITHOUT probes", func(ctx context.Context) {
		deployWorkloadsFromDir(ctx, "workload/windows-noprobes")
	})

	It("albums-linux1 returns 403 (control)", func(ctx context.Context) {
		checkLinux1Forbidden(ctx)
	})

	It("albums-win1 returns 403 (Kyverno isolation)", func(ctx context.Context) {
		checkWin1Forbidden(ctx)
	})

	It("cleans up workloads", func(ctx context.Context) {
		deleteWorkloadsIfNeeded(ctx)
	})

	It("disables security", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables ingress", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})
})

// --- Diagnostic Cycle 4: Kyverno + With Probes (reproduces known failure) ---
var _ = Describe("Diagnostic 4: Kyverno + With Probes", Ordered, Label("diag-4"), func() {
	It("enables security enhanced WITH Kyverno", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", addonName, "-t", "enhanced", "-o")
	})

	It("deploys workloads WITH probes", func(ctx context.Context) {
		deployWorkloadsFromDir(ctx, "workload/windows")
	})

	It("albums-linux1 returns 403 (control)", func(ctx context.Context) {
		checkLinux1Forbidden(ctx)
	})

	It("albums-win1 returns 403 (KNOWN FAILURE expected 200)", func(ctx context.Context) {
		checkWin1Forbidden(ctx)
	})

	It("cleans up workloads", func(ctx context.Context) {
		deleteWorkloadsIfNeeded(ctx)
	})

	It("disables security", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables ingress", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})
})
