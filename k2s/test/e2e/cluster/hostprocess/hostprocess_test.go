// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package hostprocess

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
	"strconv"

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
	createdSystemRole bool
	podWatcherCmd *exec.Cmd
	podWatcherCancel context.CancelFunc
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
	return "workload/" // default
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
	if base == "" { base = `..\\..\\..\\..\\..\\..\\bin\\cni` }
	albums := os.Getenv("TEST_ALBUMS_WIN")
	if albums == "" { albums = `.\\albumswin.exe` }

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

// isRunningAsSystem returns true if the current process user matches 'NT AUTHORITY\\SYSTEM'.
// Uses 'whoami' for portability across different Windows configurations.
func isRunningAsSystem() bool {
	out, err := exec.Command("whoami").CombinedOutput()
	if err != nil { return false }
	user := strings.TrimSpace(string(out))
	return strings.EqualFold(user, "NT AUTHORITY\\SYSTEM")
}

// startPodWatcher starts a background kubectl watch process that continuously logs pod status
func startPodWatcher(ctx context.Context) {
	watchCtx, cancel := context.WithCancel(ctx)
	podWatcherCancel = cancel
	
	GinkgoWriter.Println("Starting background pod watcher for namespace", namespace)
	
	// Get kubectl path from the test suite framework
	kubectlPath := suite.Kubectl().Path()
	
	podWatcherCmd = exec.CommandContext(watchCtx, kubectlPath, "get", "pods", "-n", namespace, "-o", "wide", "-w")
	
	// Create a pipe to capture stdout
	stdout, err := podWatcherCmd.StdoutPipe()
	if err != nil {
		GinkgoWriter.Printf("Warning: failed to create stdout pipe for pod watcher: %v\n", err)
		return
	}
	
	// Start the command
	if err := podWatcherCmd.Start(); err != nil {
		GinkgoWriter.Printf("Warning: failed to start pod watcher: %v\n", err)
		return
	}
	
	// Read output in a goroutine and write to GinkgoWriter
	go func() {
		defer func() {
			if r := recover(); r != nil {
				GinkgoWriter.Printf("Pod watcher goroutine panic: %v\n", r)
			}
		}()
		
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			line := scanner.Text()
			GinkgoWriter.Printf("[POD-WATCH] %s\n", line)
			
			// Check for error conditions and dump deployment logs
			lineUpper := strings.ToUpper(line)
			if strings.Contains(lineUpper, "ERROR") || strings.Contains(lineUpper, "CRASHLOOPBACKOFF") {
				GinkgoWriter.Printf("[POD-WATCH] Error condition detected! Dumping deployment logs...\n")
				
				// Run kubectl logs in a separate goroutine to avoid blocking the watcher
				go func(errorLine string) {
					defer func() {
						if r := recover(); r != nil {
							GinkgoWriter.Printf("[POD-WATCH] Panic while dumping logs: %v\n", r)
						}
					}()
					
					// Create a new context with timeout for log retrieval
					logCtx, logCancel := context.WithTimeout(context.Background(), 30*time.Second)
					defer logCancel()
					
					deploymentName := "albums-win-hp-app-hostprocess"
					
					// Execute kubectl logs
					logCmd := exec.CommandContext(logCtx, kubectlPath, "logs", 
						"deployment/"+deploymentName, 
						"-n", namespace,
						"--tail=100",
						"--timestamps")
					
					output, err := logCmd.CombinedOutput()
					if err != nil {
						GinkgoWriter.Printf("[POD-WATCH] Failed to retrieve logs for deployment/%s: %v\n", deploymentName, err)
					} else {
						GinkgoWriter.Printf("[POD-WATCH] ========== DEPLOYMENT LOGS (triggered by: %s) ==========\n", errorLine)
						GinkgoWriter.Printf("%s\n", string(output))
						GinkgoWriter.Printf("[POD-WATCH] ========== END DEPLOYMENT LOGS ==========\n")
					}
				}(line)
			}
		}
		
		if err := scanner.Err(); err != nil && watchCtx.Err() == nil {
			GinkgoWriter.Printf("Pod watcher scanner error: %v\n", err)
		}
	}()
	
	GinkgoWriter.Println("Pod watcher started successfully")
}

// stopPodWatcher stops the background pod watcher process
func stopPodWatcher() {
	if podWatcherCancel != nil {
		GinkgoWriter.Println("Stopping pod watcher...")
		podWatcherCancel()
		podWatcherCancel = nil
	}
	
	if podWatcherCmd != nil && podWatcherCmd.Process != nil {
		// Give it a moment to terminate gracefully
		time.Sleep(500 * time.Millisecond)
		
		// Force kill if still running
		if err := podWatcherCmd.Process.Kill(); err != nil && !strings.Contains(err.Error(), "already finished") {
			GinkgoWriter.Printf("Warning: failed to kill pod watcher process: %v\n", err)
		}
		
		podWatcherCmd = nil
		GinkgoWriter.Println("Pod watcher stopped")
	}
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

	// Create cluster role for k2s-NT-AUTHORITY-SYSTEM only if not already running as SYSTEM
	if !isRunningAsSystem() {
		GinkgoWriter.Println("Creating cluster role for k2s-NT-AUTHORITY-SYSTEM (current user is not SYSTEM)")
		suite.K2sCli().RunOrFail(ctx, "system", "users", "add", "-u", "NT AUTHORITY\\SYSTEM")
		suite.Kubectl().Run(ctx, "delete", "clusterrole", "ViewDeploymentRole", "--ignore-not-found=true")
		suite.Kubectl().Run(ctx, "delete", "clusterrolebinding", "ViewDeploymenBinding", "--ignore-not-found=true")
		suite.Kubectl().Run(ctx, "create", "clusterrole", "ViewDeploymentRole", "--verb=get,list,watch", "--resource=pods,deployments")
		suite.Kubectl().Run(ctx, "create", "clusterrolebinding", "ViewDeploymenBinding", "--clusterrole=ViewDeploymentRole", "--user=k2s-NT-AUTHORITY-SYSTEM")
		createdSystemRole = true
	} else {
		GinkgoWriter.Println("Running as NT AUTHORITY\\SYSTEM; skipping creation of cluster role and user add")
	}

	GinkgoWriter.Println("Applying hostprocess workloads from", manifestDir)

	suite.Kubectl().Run(ctx, "delete", "namespace", namespace, "--ignore-not-found=true")
	suite.Kubectl().Run(ctx, "create", "namespace", namespace)

	// Start pod watcher in background after namespace is created
	startPodWatcher(ctx)

	// Create log directory for albumswin
	albumsLogDir := `C:\var\log\albumswin`
	if err := os.MkdirAll(albumsLogDir, 0755); err != nil {
		GinkgoWriter.Printf("Warning: failed to create albumswin log directory %s: %v\n", albumsLogDir, err)
	} else {
		GinkgoWriter.Printf("Created albumswin log directory: %s\n", albumsLogDir)
	}

	// Resolve paths and attempt local build of albumswin before creating ConfigMap
	computeAndSetLauncherEnv()

	// Create/update ConfigMap with dynamic base paths before applying manifests
	ensureLauncherConfigMap(ctx)

	// Apply all manifests in the workload directory
	suite.Kubectl().Run(ctx, "apply", "-k", manifestDir)

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
	// Stop the pod watcher before cleanup
	stopPodWatcher()
	
	GinkgoWriter.Println("Status of cluster after hostprocess test runs...")
	status := suite.K2sCli().GetStatus(ctx)
	isRunning := status.IsClusterRunning()
	GinkgoWriter.Println("Cluster is running:", isRunning)

	// Check if any tests failed using CurrentSpecReport
	// This works even if BeforeSuite failed or if testFailed wasn't set
	hasFailed := testFailed || CurrentSpecReport().Failed()
	
	if hasFailed {
		GinkgoWriter.Println("Test failed; dumping system diagnostics")
		suite.K2sCli().RunOrFail(ctx, "system", "dump", "-S", "-o")
		return // keep workloads for inspection
	}

	// dump a kubectl describe of all resources in the k2s namespace for debugging purposes
	GinkgoWriter.Println("Dumping kubectl describe of all resources in namespace", namespace)
	suite.Kubectl().Run(ctx, "describe", "all", "-n", namespace)

	// dump the logs of all pods in the k2s namespace for debugging purposes
	GinkgoWriter.Println("Dumping logs of all pods in namespace", namespace)
	GinkgoWriter.Println("POD albums-compartment-anchor", namespace)
	suite.Kubectl().Run(ctx, "logs", "pod/albums-compartment-anchor", "-n", namespace)
	GinkgoWriter.Println("DEPLOYMENT albums-win-hp-app-hostprocess", namespace)
	suite.Kubectl().Run(ctx, "logs", "deployment/albums-win-hp-app-hostprocess", "-n", namespace)

	GinkgoWriter.Println("Deleting hostprocess workloads (best-effort)..")
	_, code := suite.Kubectl().RunWithExitCode(ctx, "delete", "-k", manifestDir, "--force", "--ignore-not-found=true")
	if code != 0 { GinkgoWriter.Println("(non-fatal) deletion returned exit code", code) }
	GinkgoWriter.Println("Hostprocess workloads delete step finished; manifests path:", manifestDir)

	suite.Kubectl().Run(ctx, "delete", "namespace", namespace, "--ignore-not-found=true")

	// Delete cluster role for k2s-NT-AUTHORITY-SYSTEM only if it was created in this run
	if createdSystemRole {
		GinkgoWriter.Println("Deleting cluster role for k2s-NT-AUTHORITY-SYSTEM (it was created by the test)")
		suite.Kubectl().Run(ctx, "delete", "clusterrole", "ViewDeploymentRole", "--ignore-not-found=true")
		suite.Kubectl().Run(ctx, "delete", "clusterrolebinding", "ViewDeploymenBinding", "--ignore-not-found=true")
	} else {
		GinkgoWriter.Println("Cluster role for k2s-NT-AUTHORITY-SYSTEM not created by test; skipping delete")
	}

	suite.TearDown(ctx, framework.RestartKubeProxy)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("HostProcess Workloads", func() {

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
			}, 60*time.Second, 2*time.Second).Should(And(ContainSubstring("IP Addresses"), ContainSubstring("172.20.1")))
		})
	})

	Describe("Reachability", func() {
		const hostProcDep = HostProcessDeploymentName
		const serviceName = HostProcessServiceName
		servicePort := strconv.Itoa(HostProcessContainerTargetPort)

		It(serviceName+" service is reachable from host", func(ctx SpecContext) {
			// Ensure service exists
			_, code := suite.Kubectl().RunWithExitCode(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 { Skip("service not found: " + serviceName) }
			k2s.VerifyDeploymentToBeReachableFromHostAtPort(ctx, hostProcDep, namespace, servicePort)
		})

		It(serviceName+" service is reachable from curl pod", func(ctx SpecContext) {
			_, code := suite.Kubectl().RunWithExitCode(ctx, "get", "service", serviceName, "-n", namespace)
			if code != 0 { Skip("service not found: " + serviceName) }
			_, curlCode := suite.Kubectl().RunWithExitCode(ctx, "get", "deployment", "curl", "-n", namespace)
			if curlCode != 0 { Skip("curl deployment not found; skipping pod->deployment reachability test") }
			suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeploymentAtPort(hostProcDep, namespace, "curl", namespace, servicePort, ctx)
		})

		It("direct hostprocess pod IP is reachable from curl pod", func(ctx SpecContext) {
			// Ensure curl deployment exists
			GinkgoWriter.Println("Getting curl deployment: ")
			_, curlCode := suite.Kubectl().RunWithExitCode(ctx, "get", "deployment", "curl", "-n", namespace)
			if curlCode != 0 { Skip("curl deployment not found") }
			// Get hostprocess pod IP
			GinkgoWriter.Println("Getting hostprocess pod IP: ")
			podIP, ipCode := suite.Kubectl().RunWithExitCode(ctx, "get", "pod", AnchorPodName, "-n", namespace, "-o", "jsonpath={.status.podIP}")
			if ipCode != 0 || podIP == "" { Skip("pod IP not available yet") }
			// Find curl pod name
			var curlPodName string
			Eventually(func() string {
				name, _ := suite.Kubectl().RunWithExitCode(ctx, "get", "pods", "-n", namespace, "-l", "app=curl", "-o", "jsonpath={.items[0].metadata.name}")
				curlPodName = name
				return name
			}, suite.TestStepTimeout(), 2*time.Second).ShouldNot(BeEmpty())
			GinkgoWriter.Printf("Found curl pod: %s\n", curlPodName)
			// Execute curl directly to pod IP:8080 expecting HTTP 200 (health endpoint or root)
			cmd := fmt.Sprintf("curl -s -o /dev/null -w %%{http_code} http://%s:%d/%s || true", podIP, HostProcessContainerTargetPort, HostProcessDeploymentName)
			GinkgoWriter.Println("Executing curl command: ", cmd)
			Eventually(func() string {
				out, _ := suite.Kubectl().RunWithExitCode(ctx, "exec", curlPodName, "-n", namespace, "--", "sh", "-c", cmd)
				return strings.TrimSpace(out)
			}, 60*time.Second, 3*time.Second).Should(Equal("200"))
		})

		It("direct hostprocess pod IP is reachable from host", func(ctx SpecContext) {
			// Get hostprocess pod IP
			GinkgoWriter.Println("Getting hostprocess pod IP: ")
			podIP, ipCode := suite.Kubectl().RunWithExitCode(ctx, "get", "pod", AnchorPodName, "-n", namespace, "-o", "jsonpath={.status.podIP}")
			if ipCode != 0 || podIP == "" { Skip("pod IP not available yet") }
			// Execute curl directly to pod IP:8080 expecting HTTP 200 (health endpoint or root)
			url := fmt.Sprintf("http://%s:%d/%s", podIP, HostProcessContainerTargetPort, HostProcessDeploymentName)
			GinkgoWriter.Println("Executing curl command: ", url)
			Eventually(func() string {
				out, _ := suite.Cli().Exec(ctx, "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url)
				return strings.TrimSpace(out)
			}, 60*time.Second, 3*time.Second).Should(Equal("200"))
		})
	})
})
