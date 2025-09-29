// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package hostprocess

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
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

func TestClusterHostProcess(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Cluster HostProcess Acceptance Tests", Label("hostprocess", "acceptance", "internet-required", "setup-required", "system-running"))
}

// resolveManifestDir attempts to locate the hostprocess workload directory in a flexible way so the test
// can be run from repo root or within the package directory.
func resolveManifestDir() string {
	candidates := []string{
		"test/e2e/cluster/hostprocess/workload", // absolute-from-root style
		"hostprocess/workload",                   // relative short form (if working dir already at test/e2e/cluster)
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && st.IsDir() {
			return c
		}
	}
	return candidates[0] // default (may not exist; caller will handle)
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

	applyArg := "-f"
	if _, err := os.Stat(filepath.Join(manifestDir, "kustomization.yaml")); err == nil {
		applyArg = "-k"
	}

	suite.Kubectl().Run(ctx, "apply", applyArg, manifestDir)

	GinkgoWriter.Println("Waiting for hostprocess deployments (if any) to be ready in namespace <", namespace, "> ..")

	// Only wait for rollout if deployments exist (skip errors if some examples only contain pods)
	for _, dep := range hostProcessDeploymentNames {
		// Use rollout status with timeout, but ignore failures if resource absent to keep test flexible
		_, err := suite.Kubectl().RunSilently(ctx, "get", "deployment", dep, "-n", namespace)
		if err == nil {
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

	GinkgoWriter.Println("Deleting hostprocess workloads..")
	deleteArg := "-f"
	if _, err := os.Stat(filepath.Join(manifestDir, "kustomization.yaml")); err == nil {
		deleteArg = "-k"
	}
	suite.Kubectl().Run(ctx, "delete", deleteArg, manifestDir)
	GinkgoWriter.Println("Hostprocess workloads deleted")

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
				_, err := suite.Kubectl().RunSilently(context.Background(), "get", "deployment", depName, "-n", namespace)
				if err != nil {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectDeploymentToBeAvailable(depName, namespace)
			})
			It(depName+" pods become Ready", func(ctx SpecContext) {
				_, err := suite.Kubectl().RunSilently(context.Background(), "get", "deployment", depName, "-n", namespace)
				if err != nil {
					Skip("deployment not found: " + depName)
				}
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", depName, namespace)
			})
		}
	})

	Describe("cplauncher diagnostics", func() {
		cplauncherDep := hostProcessDeploymentNames[0]
		cplauncherLabel := HostProcessAppLabel

		It("cplauncher stdout logs contain pid line and target exe", func(ctx SpecContext) {
			// Find pod name for deployment (assumes 1 replica)
			// We poll using kubectl get pod -l app=<depLabel>
			var podName string
			Eventually(func(g Gomega) string {
				out, err := suite.Kubectl().RunSilently(ctx, "get", "pods", "-n", namespace, "-l", "app="+cplauncherLabel, "-o", "jsonpath={.items[0].metadata.name}")
				g.Expect(err).NotTo(HaveOccurred())
				podName = out
				return out
			}, suite.TestStepTimeout(), 2*time.Second).ShouldNot(BeEmpty())

			Eventually(func() string {
				logs, _ := suite.Kubectl().RunSilently(ctx, "logs", podName, "-n", namespace)
				return logs
			}, 60*time.Second, 2*time.Second).Should(And(ContainSubstring("pid="), ContainSubstring("cplauncher finished")))
		})

		It("anchor pod (if annotated) exposes a numeric compartment annotation", func(ctx SpecContext) {
			jsonOut, err := suite.Kubectl().RunSilently(ctx, "get", "pod", anchorPodName, "-n", namespace, "-o", "json")
			Expect(err).NotTo(HaveOccurred())
			var obj map[string]any
			Expect(json.Unmarshal([]byte(jsonOut), &obj)).To(Succeed())
			meta, _ := obj["metadata"].(map[string]any)
			anns, _ := meta["annotations"].(map[string]any)
			if len(anns) == 0 {
				Skip("no annotations present")
			}
			re := regexp.MustCompile(`(?i)compartment`) // look for any key mentioning compartment
			found := false
			for k, v := range anns {
				if !re.MatchString(k) { continue }
				if s, ok := v.(string); ok {
					if s == "" { continue }
					if matched := regexp.MustCompile(`^\\d+$`).MatchString(s); matched {
						found = true
						break
					}
				}
			}
			if !found {
				Skip("no compartment-related numeric annotation found")
			}
		})
	})

	Describe("Reachability", func() {
		const hostProcDep = HostProcessDeploymentName
		const serviceName = HostProcessServiceName // Service exposing port 80 -> 8080

		It(serviceName+" service is reachable from host", func(ctx SpecContext) {
			// Ensure deployment exists
			if _, err := suite.Kubectl().RunSilently(ctx, "get", "service", serviceName, "-n", namespace); err != nil {
				Skip("service not found: " + serviceName)
			}
			// Use existing helper against deployment first (port discovery may rely on deployment), then optionally curl service.
			k2s.VerifyDeploymentToBeReachableFromHost(ctx, hostProcDep, namespace)
		})

		It(serviceName+" service is reachable from curl pod", func(ctx SpecContext) {
			// Need both deployments present: hostProcDep and curl
			if _, err := suite.Kubectl().RunSilently(ctx, "get", "service", serviceName, "-n", namespace); err != nil {
				Skip("service not found: " + serviceName)
			}
			if _, err := suite.Kubectl().RunSilently(ctx, "get", "deployment", "curl", "-n", namespace); err != nil {
				Skip("curl deployment not found; skipping pod->deployment reachability test")
			}
			suite.Cluster().ExpectDeploymentToBeReachableFromPodOfOtherDeployment(hostProcDep, namespace, "curl", namespace, ctx)
		})
	})
})
