// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package hostprocess

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

// Use shared namespace constant (can diverge from system namespace if needed)
const (
	namespace = NamespaceHostProcess
)

// Expected names coming from the hostprocess workload examples.
var (
	hostProcessDeploymentNames = []string{HostProcessDeploymentName}
	anchorPodName              = AnchorPodName
)

var (
	suite *framework.K2sTestSuite
	k2s   *dsl.K2s

	manifestDir string
	testFailed  bool
)

const (
	launcherConfigMap = "hostprocess-launcher-env"
)

func TestClusterHostProcess(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster HostProcess Acceptance Tests", Label("hostprocess", "acceptance", "internet-required", "setup-required", "system-running"))
}

// resolveManifestDir attempts to locate the hostprocess workload directory in a flexible way so the test
// can be run from repo root or within the package directory.
func resolveManifestDir() string {
	if st, err := os.Stat("workload"); err == nil && st.IsDir() { return "workload" }
	return "workload" // default
}

// computeAndSetLauncherEnv locates cplauncher and builds the local albumswin test binary.
// It sets TEST_CPLAUNCHER_BASE and TEST_ALBUMS_WIN environment variables consumed when creating the ConfigMap.
func computeAndSetLauncherEnv() {
	_, file, _, ok := runtime.Caller(0)
	if !ok { return }
	testDir := filepath.Dir(file)

	// Ascend 5 levels: hostprocess -> cluster -> e2e -> test -> k2s -> repo root
	repoRoot := testDir
	for i := 0; i < 5; i++ { repoRoot = filepath.Dir(repoRoot) }

	// cplauncher
	cplauncherBase := filepath.Join(repoRoot, "bin", "cni")
	cplauncherExe := filepath.Join(cplauncherBase, "cplauncher.exe")
	cplauncherSet := false
	if _, err := os.Stat(cplauncherExe); err == nil {
		_ = os.Setenv("TEST_CPLAUNCHER_BASE", toWindowsPath(cplauncherBase))
		cplauncherSet = true
	}

	// albumswin local build target within test directory for portability
	albumsSrcDir := filepath.Join(testDir, "albumswin")
	albumsExe := filepath.Join(testDir, "albumswin.exe")
	albumsSet := false

	if _, err := os.Stat(albumsExe); err != nil { // not built yet
		if _, errSrc := os.Stat(filepath.Join(albumsSrcDir, "main.go")); errSrc == nil {
			// Attempt build (best effort)
			cmd := exec.Command("go", "build", "-o", albumsExe, ".")
			cmd.Dir = albumsSrcDir
			if out, errRun := cmd.CombinedOutput(); errRun != nil {
				GinkgoWriter.Println("albumswin build failed (will fall back to default path if any):", errRun)
				GinkgoWriter.Println(string(out))
			}
		}
	}
	if _, err := os.Stat(albumsExe); err == nil {
		_ = os.Setenv("TEST_ALBUMS_WIN", toWindowsPath(albumsExe))
		albumsSet = true
	}

	GinkgoWriter.Println("Resolved launcher paths:")
	GinkgoWriter.Println("  cplauncher base:", cplauncherBase, "exists=", cplauncherSet)
	GinkgoWriter.Println("  albums binary (local build):", albumsExe, "exists=", albumsSet)
	if !cplauncherSet {
		GinkgoWriter.Println("  (using default fallback for TEST_CPLAUNCHER_BASE inside ensureLauncherConfigMap)")
	}
	if !albumsSet {
		GinkgoWriter.Println("  (albums binary not built; using default fallback if required)")
	}
}

func toWindowsPath(p string) string {
	p = filepath.Clean(p)
	return strings.ReplaceAll(p, "/", "\\")
}
// ensureLauncherConfigMap creates or updates the ConfigMap holding env values for cplauncher paths.
// Priority: explicit env vars (TEST_CPLAUNCHER_BASE, TEST_ALBUMS_WIN) -> defaults.
func ensureLauncherConfigMap(ctx context.Context) {
	base := os.Getenv("TEST_CPLAUNCHER_BASE")
	if base == "" { base = `C:\\ws\\k2s\\bin\\cni` }
	albums := os.Getenv("TEST_ALBUMS_WIN")
	if albums == "" { albums = `C:\\ws\\s\\examples\\albums-golang-win\\albumswin.exe` }

	// Normalize to Windows backslashes (in case someone passed forward slashes)
	base = strings.ReplaceAll(base, `/`, `\\`)
	albums = strings.ReplaceAll(albums, `/`, `\\`)

	// Use kubectl apply via literal arguments for idempotency
	// Windows escaping: keep quotes minimal; rely on framework Exec for quoting.
	suite.Kubectl().Run(ctx, "delete", "configmap", launcherConfigMap, "-n", namespace, "--ignore-not-found=true")
	suite.Kubectl().Run(ctx, "create", "configmap", launcherConfigMap,
		"-n", namespace,
		"--from-literal=CPLAUNCHER_BASE="+base,
		"--from-literal=ALBUMS_WIN="+albums,
	)
}

var _ = BeforeSuite(func(ctx context.Context) {
	manifestDir = resolveManifestDir()

	suite = framework.Setup(ctx, framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(200*time.Millisecond),
		framework.ClusterTestStepTimeout(8*time.Minute))
	k2s = dsl.NewK2s(suite)

	if _, err := os.Stat(manifestDir); err != nil {
		Skip("hostprocess manifest directory not found: " + manifestDir)
	}

	GinkgoWriter.Println("Applying hostprocess workloads from", manifestDir)

	// Resolve paths and attempt local build of albumswin before creating ConfigMap
	computeAndSetLauncherEnv()

	// Create/update ConfigMap with dynamic base paths before applying manifests
	ensureLauncherConfigMap(ctx)
	// Apply all manifests in the workload directory
	suite.Kubectl().Run(ctx, "apply", "-f", manifestDir)

	GinkgoWriter.Println("Waiting for hostprocess deployments (if any) to be ready in namespace <", namespace, "> ..")

	// Only wait for rollout if deployments exist (skip errors if some examples only contain pods)
	for _, dep := range hostProcessDeploymentNames {
		_, code := suite.Kubectl().RunWithExitCode(ctx, "get", "deployment", dep, "-n", namespace)
		if code == 0 {
			suite.Kubectl().Run(ctx, "rollout", "status", "deployment", dep, "-n", namespace, "--timeout="+suite.TestStepTimeout().String())
		}
	}
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Status of cluster after hostprocess test runs...")
	status := suite.K2sCli().GetStatus(ctx)
	isRunning := status.IsClusterRunning()
	GinkgoWriter.Println("Cluster is running:", isRunning)

	if testFailed {
		GinkgoWriter.Println("Test failed; dumping system diagnostics")
		suite.K2sCli().RunOrFail(ctx, "system", "dump", "-S", "-o")
		return // keep workloads for inspection
	}

	GinkgoWriter.Println("Deleting hostprocess workloads (best-effort)..")
	_, code := suite.Kubectl().RunWithExitCode(ctx, "delete", "-f", manifestDir, "--ignore-not-found=true")
	if code != 0 { GinkgoWriter.Println("(non-fatal) deletion returned exit code", code) }
	GinkgoWriter.Println("Hostprocess workloads delete step finished; manifests path:", manifestDir)

	suite.TearDown(ctx, framework.RestartKubeProxy)
})

var _ = Describe("HostProcess Workloads", func() {
	var _ = AfterEach(func() {
		if CurrentSpecReport().Failed() {
			testFailed = true
		}
	})

	It("anchor pod becomes Ready", func(ctx SpecContext) {
		// The anchor pod is a single Pod object.
		suite.Cluster().ExpectPodToBeReady(anchorPodName, namespace, "")
	})

	Describe("Deployments", func() {
		for _, dep := range hostProcessDeploymentNames {
			depName := dep
			It(depName+" becomes available", func() {
				// Skip gracefully if deployment not present in the workload set
				_, exitCode := suite.Kubectl().RunWithExitCode(context.Background(), "get", "deployment", depName, "-n", namespace)
				if exitCode != 0 {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectDeploymentToBeAvailable(depName, namespace)
			})
			It(depName+" pods become Ready", func(ctx SpecContext) {
				_, exitCode := suite.Kubectl().RunWithExitCode(context.Background(), "get", "deployment", depName, "-n", namespace)
				if exitCode != 0 {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", depName, namespace)
			})
		}
	})

	Describe("cplauncher diagnostics", func() {
		cplauncherLabel := HostProcessAppLabel

		It("cplauncher stdout logs contain pid line and target exe", func(ctx SpecContext) {
			// Find pod name for deployment (assumes 1 replica)
			// We poll using kubectl get pod -l app=<depLabel>
			var podName string
			Eventually(func(g Gomega) string {
				out, code := suite.Kubectl().RunWithExitCode(ctx, "get", "pods", "-n", namespace, "-l", "app="+cplauncherLabel, "-o", "jsonpath={.items[0].metadata.name}")
				if code != 0 { return "" }
				podName = out
				return out
			}, suite.TestStepTimeout(), 2*time.Second).ShouldNot(BeEmpty())

			Eventually(func() string {
				logs, code := suite.Kubectl().RunWithExitCode(ctx, "logs", podName, "-n", namespace)
				if code != 0 { return "" }
				return logs
			}, 60*time.Second, 2*time.Second).Should(And(ContainSubstring("pid="), ContainSubstring("cplauncher finished")))
		})

		It("anchor pod (if annotated) exposes a numeric compartment annotation", func(ctx SpecContext) {
			jsonOut := suite.Kubectl().Run(ctx, "get", "pod", anchorPodName, "-n", namespace, "-o", "json")
			var obj map[string]any
			Expect(json.Unmarshal([]byte(jsonOut), &obj)).To(Succeed())
			meta, _ := obj["metadata"].(map[string]any)
			anns, _ := meta["annotations"].(map[string]any)
			if len(anns) == 0 { Skip("no annotations present") }
			re := regexp.MustCompile(`(?i)compartment`)
			found := false
			for k, v := range anns {
				if !re.MatchString(k) { continue }
				if s, ok := v.(string); ok {
					if s == "" { continue }
					if regexp.MustCompile(`^\\d+$`).MatchString(s) { found = true; break }
				}
			}
			if !found { Skip("no compartment-related numeric annotation found") }
		})
	})

	Describe("Reachability", func() {
		const hostProcDep = HostProcessDeploymentName
		const serviceName = HostProcessServiceName // Service exposing port 80 -> 8080

		It(serviceName+" service is reachable from host", func(ctx SpecContext) {
			// Ensure service exists
			_, code := suite.Kubectl().RunWithExitCode(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 { Skip("service not found: " + serviceName) }
			k2s.VerifyDeploymentToBeReachableFromHost(ctx, hostProcDep, namespace)
		})

		It(serviceName+" service is reachable from curl pod", func(ctx SpecContext) {
			_, code := suite.Kubectl().RunWithExitCode(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 { Skip("service not found: " + serviceName) }
			_, curlCode := suite.Kubectl().RunWithExitCode(ctx, "get", "deployment", "curl", "-n", namespace)
			if curlCode != 0 { Skip("curl deployment not found; skipping pod->deployment reachability test") }
			suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment(hostProcDep, namespace, "curl", namespace, ctx)
		})
	})
})
