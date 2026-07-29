// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

package ceph_share

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	bos "os"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	addonName          = "storage"
	implementationName = "ceph"
	namespace          = "ceph-share-test"
	kubemasterIP       = "172.19.1.100"

	namespaceManifestPath = "workloads/ceph-share-test-namespace.yaml"
	rwxManifestDir        = "workloads/rwx"

	pvcName      = "ceph-share-test-pvc"
	writerPod    = "ceph-share-writer"
	readerPod    = "ceph-share-reader"
	testFile     = "/mnt/data/hello.txt"
	testMarker   = "hello from k2s ceph e2e"
	cephDataPool = "cephfs.cephfs.data"

	testClusterTimeout     = time.Minute * 20
	addonEnableMaxAttempts = 2
	addonEnableRetryDelay  = 10 * time.Second
)

var (
	suite              *framework.K2sTestSuite
	k2s                *dsl.K2s
	testFailed         = false
	originalConfigPath string
)

func TestCephStorage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Acceptance Tests", Label("addon", "acceptance", "internet-required", "setup-required", "invasive", "storage-ceph", "ceph", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(
		ctx,
		framework.SystemMustBeRunning,
		framework.EnsureAddonsAreDisabled,
		framework.ClusterTestStepTimeout(testClusterTimeout),
	)
	k2s = dsl.NewK2s(suite)

	suite.Kubectl().MustExec(ctx, "apply", "-f", namespaceManifestPath)

	originalConfigPath = filepath.Join(suite.RootDir(), "addons", "storage", "ceph", "config", "ceph-config.json")
	_, err := bos.Stat(originalConfigPath)
	Expect(err).ToNot(HaveOccurred(), "expected addon Ceph config to exist at '%s'", originalConfigPath)
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	// Best-effort cleanup in failure paths.
	suite.Kubectl().Exec(ctx, "delete", "-k", rwxManifestDir)
	suite.Kubectl().Exec(ctx, "delete", "-f", namespaceManifestPath)
	suite.K2sCli().Exec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("storage ceph addon", Ordered, func() {
	Describe("status command", func() {
		It("shows disabled in default output", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)
			Expect(output).To(SatisfyAll(
				ContainSubstring("ADDON STATUS"),
				ContainSubstring("disabled"),
			))
		})

		It("shows disabled in JSON output", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

			var st status.AddonPrintStatus
			Expect(json.Unmarshal([]byte(output), &st)).To(Succeed())
			Expect(st.Name).To(Equal(addonName))
			Expect(st.Implementation).To(Equal(implementationName))
			Expect(st.Enabled).NotTo(BeNil())
			Expect(*st.Enabled).To(BeFalse())
		})
	})

	Describe("enable, run workload, disable", func() {
		It("enables the addon", func(ctx context.Context) {
			output := enableCephAddonWithRetry(ctx)
			Expect(output).To(SatisfyAll(
				ContainSubstring("enable"),
				ContainSubstring(addonName),
				ContainSubstring(implementationName),
			))

			k2s.VerifyAddonIsEnabled(addonName, implementationName)
		})

		It("shows enabled status", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName)
			Expect(output).To(SatisfyAll(
				ContainSubstring("ADDON STATUS"),
				ContainSubstring("enabled"),
			))
		})

		It("maps a data object to 3 distinct acting OSDs", func(ctx context.Context) {
			// Placement test: verifies an object maps to three unique acting OSDs (replication fan-out),
			// confirming the CRUSH rule and pool replica behavior are wired as expected.
			clusterHostNode, err := getClusterHostNodeFromCephConfig(originalConfigPath)
			Expect(err).ToNot(HaveOccurred())

			cephHostIP, err := getDashboardTargetHost(clusterHostNode, suite.SetupInfo().Config.Host().K2sSetupConfigDir())
			Expect(err).ToNot(HaveOccurred())

			objectName := fmt.Sprintf("k2s-ceph-repl-e2e-%d", time.Now().UnixNano())

			runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- rados -p %s put %s /etc/hosts", cephDataPool, objectName))
			DeferCleanup(func(ctx context.Context) {
				runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- rados -p %s rm %s || true", cephDataPool, objectName))
			})

			mapOutput := runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- ceph osd map %s %s --format json", cephDataPool, objectName))

			var mapping cephOSDMapResult
			jsonBlob, err := extractJSONBlob(mapOutput)
			Expect(err).ToNot(HaveOccurred(), "failed to parse ceph osd map output: %s", mapOutput)
			Expect(json.Unmarshal([]byte(jsonBlob), &mapping)).To(Succeed(), "failed to decode ceph osd map JSON: %s", jsonBlob)

			Expect(len(mapping.Acting)).To(Equal(3), "expected 3 acting OSD replicas for object %q, got: %v", objectName, mapping.Acting)
			Expect(countDistinctInts(mapping.Acting)).To(Equal(3), "expected acting OSD set to contain 3 distinct OSD IDs, got: %v", mapping.Acting)
		})

		It("keeps object readable when one acting OSD is out", func(ctx context.Context) {
			// Runtime resiliency test: writes an object, marks one acting OSD out, then asserts
			// the object stays readable from the same pool while Ceph serves from remaining replicas.
			clusterHostNode, err := getClusterHostNodeFromCephConfig(originalConfigPath)
			Expect(err).ToNot(HaveOccurred())

			cephHostIP, err := getDashboardTargetHost(clusterHostNode, suite.SetupInfo().Config.Host().K2sSetupConfigDir())
			Expect(err).ToNot(HaveOccurred())

			objectName := fmt.Sprintf("k2s-ceph-runtime-proof-%d", time.Now().UnixNano())
			outputFilePath := fmt.Sprintf("/tmp/%s.out", objectName)

			runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- rados -p %s put %s /etc/hosts", cephDataPool, objectName))
			DeferCleanup(func(ctx context.Context) {
				runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- rados -p %s rm %s || true", cephDataPool, objectName))
			})

			mapOutput := runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- ceph osd map %s %s --format json", cephDataPool, objectName))
			var mapping cephOSDMapResult
			jsonBlob, err := extractJSONBlob(mapOutput)
			Expect(err).ToNot(HaveOccurred(), "failed to parse ceph osd map output: %s", mapOutput)
			Expect(json.Unmarshal([]byte(jsonBlob), &mapping)).To(Succeed(), "failed to decode ceph osd map JSON: %s", jsonBlob)
			Expect(len(mapping.Acting)).To(BeNumerically(">=", 2), "expected at least 2 acting OSDs before failure test, got: %v", mapping.Acting)

			osdToOut := mapping.Acting[0]
			runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- ceph osd out %d", osdToOut))
			DeferCleanup(func(ctx context.Context) {
				runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- ceph osd in %d || true", osdToOut))
			})

			Eventually(func() string {
				out := runSSHOnCephHost(ctx, cephHostIP, fmt.Sprintf("sudo cephadm shell -- bash -lc \"rados -p %s get %s %s && cat %s; rc=$?; rm -f %s; exit $rc\"", cephDataPool, objectName, outputFilePath, outputFilePath, outputFilePath))
				return strings.TrimSpace(out)
			}).WithTimeout(2*time.Minute).WithPolling(5*time.Second).Should(ContainSubstring("localhost"), "object should remain readable after taking one acting OSD out")
		})

		It("makes Ceph dashboard URL reachable", func(ctx context.Context) {
			dashboardURL, err := getExpectedCephDashboardURL(originalConfigPath, suite.SetupInfo().Config.Host().K2sSetupConfigDir())
			Expect(err).ToNot(HaveOccurred())

			Eventually(func() error {
				_, getErr := suite.HttpClient(&tls.Config{InsecureSkipVerify: true}).Get(ctx, dashboardURL)
				return getErr
			}).WithTimeout(3*time.Minute).WithPolling(10*time.Second).Should(Succeed(), "Ceph dashboard URL should be reachable: %s", dashboardURL)
		})

		It("deploys Ceph RWX workload", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "apply", "-k", rwxManifestDir)
		})

		It("binds the Ceph PVC", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx,
				"wait",
				"--for=jsonpath={.status.phase}=Bound",
				"pvc/"+pvcName,
				"-n", namespace,
				"--timeout=180s",
			)
		})

		It("runs writer and reader pods", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+writerPod, "-n", namespace, "--timeout=180s")
			suite.Kubectl().MustExec(ctx, "wait", "--for=condition=Ready", "pod/"+readerPod, "-n", namespace, "--timeout=180s")
		})

		It("shares data across pods through CephFS", func(ctx context.Context) {
			Eventually(func() string {
				out, exitCode := suite.Kubectl().Exec(ctx, "exec", "-n", namespace, readerPod, "--", "cat", testFile)
				if exitCode != 0 {
					return ""
				}
				return strings.TrimSpace(out)
			}).WithTimeout(3 * time.Minute).WithPolling(5 * time.Second).Should(Equal(testMarker))
		})

		It("deletes Ceph workload resources", func(ctx context.Context) {
			suite.Kubectl().MustExec(ctx, "delete", "-k", rwxManifestDir)
		})

		It("disables the addon", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
			k2s.VerifyAddonIsDisabled(addonName, implementationName)

			Eventually(func(g Gomega) {
				st := getAddonStatusJSON(ctx, g)
				g.Expect(st.Name).To(Equal(addonName))
				g.Expect(st.Implementation).To(Equal(implementationName))
				g.Expect(st.Enabled).NotTo(BeNil())
				g.Expect(*st.Enabled).To(BeFalse())
			}).WithTimeout(2 * time.Minute).WithPolling(5 * time.Second).Should(Succeed())
		})
	})
})

func enableCephAddonWithRetry(ctx context.Context) string {
	lastOutput := ""
	lastExitCode := -1

	for attempt := 1; attempt <= addonEnableMaxAttempts; attempt++ {
		output, exitCode := suite.K2sCli().Exec(ctx, "addons", "enable", addonName, implementationName, "-o")
		if exitCode == 0 {
			return output
		}

		lastOutput = output
		lastExitCode = exitCode

		if attempt < addonEnableMaxAttempts {
			GinkgoWriter.Printf("Retrying addon enable after failed attempt %d/%d (exit code: %d).\n", attempt, addonEnableMaxAttempts, exitCode)
			suite.K2sCli().Exec(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")
			time.Sleep(addonEnableRetryDelay)
		}
	}

	Expect(lastExitCode).To(Equal(0), "'k2s addons enable %s %s -o' failed after %d attempts. Last output:\n%s", addonName, implementationName, addonEnableMaxAttempts, lastOutput)
	return lastOutput
}

func getAddonStatusJSON(ctx context.Context, g Gomega) status.AddonPrintStatus {
	output := suite.K2sCli().MustExec(ctx, "addons", "status", addonName, implementationName, "-o", "json")

	var st status.AddonPrintStatus
	g.Expect(json.Unmarshal([]byte(output), &st)).To(Succeed())
	return st
}

func getExpectedCephDashboardURL(cephConfigPath, setupConfigDir string) (string, error) {
	clusterHostNode, err := getClusterHostNodeFromCephConfig(cephConfigPath)
	if err != nil {
		return "", err
	}
	targetHost, err := getDashboardTargetHost(clusterHostNode, setupConfigDir)
	if err != nil {
		return "", err
	}

	return fmt.Sprintf("https://%s:8443/", targetHost), nil
}

func getClusterHostNodeFromCephConfig(cephConfigPath string) (string, error) {
	config, err := readJSONAsMap(cephConfigPath)
	if err != nil {
		return "", err
	}

	value, found := config["clusterHostNode"]
	if !found {
		return "", fmt.Errorf("clusterHostNode is missing in '%s'", cephConfigPath)
	}

	clusterHostNode, ok := value.(string)
	if !ok || strings.TrimSpace(clusterHostNode) == "" {
		return "", fmt.Errorf("clusterHostNode in '%s' is empty or not a string", cephConfigPath)
	}
	return strings.TrimSpace(clusterHostNode), nil
}

// For the control plane node, use its well-known hostname directly.

func getDashboardTargetHost(clusterHostNode, setupConfigDir string) (string, error) {
	if strings.EqualFold(clusterHostNode, "kubemaster") {
		return kubemasterIP, nil
	}

	clusterConfigPath := filepath.Join(setupConfigDir, "cluster.json")
	clusterConfig, err := readJSONAsMap(clusterConfigPath)
	if err != nil {
		return "", fmt.Errorf("failed to read cluster config '%s': %w", clusterConfigPath, err)
	}
	ip, err := findNodeIPInClusterConfig(clusterConfig, clusterHostNode)
	if err != nil {
		return "", fmt.Errorf("%w in '%s'", err, clusterConfigPath)
	}
	return ip, nil
}

func findNodeIPInClusterConfig(clusterConfig map[string]any, targetNodeName string) (string, error) {
	nodesValue, hasNodes := clusterConfig["nodes"]
	if !hasNodes {
		return "", fmt.Errorf("nodes are missing")
	}

	if nodesArray, ok := nodesValue.([]any); ok {
		return findNodeIPInArray(nodesArray, targetNodeName)
	}

	return findNodeIPInObject(nodesValue, targetNodeName)
}

func findNodeIPInArray(nodesArray []any, targetNodeName string) (string, error) {
	for _, node := range nodesArray {
		name, ip := extractNodeNameAndIP(node)
		if strings.EqualFold(name, targetNodeName) {
			if ip == "" {
				return "", fmt.Errorf("node '%s' does not have an IpAddress", targetNodeName)
			}
			return ip, nil
		}
	}
	return "", fmt.Errorf("clusterHostNode '%s' was not found", targetNodeName)
}

func findNodeIPInObject(nodeValue any, targetNodeName string) (string, error) {
	name, ip := extractNodeNameAndIP(nodeValue)
	if strings.EqualFold(name, targetNodeName) {
		if ip == "" {
			return "", fmt.Errorf("node '%s' does not have an IpAddress", targetNodeName)
		}
		return ip, nil
	}
	return "", fmt.Errorf("clusterHostNode '%s' was not found", targetNodeName)
}

func extractNodeNameAndIP(node any) (string, string) {
	nodeMap, ok := node.(map[string]any)
	if !ok {
		return "", ""
	}

	name, _ := nodeMap["Name"].(string)
	if strings.TrimSpace(name) == "" {
		name, _ = nodeMap["name"].(string)
	}

	ip, _ := nodeMap["IpAddress"].(string)
	if strings.TrimSpace(ip) == "" {
		ip, _ = nodeMap["ipAddress"].(string)
	}

	return strings.TrimSpace(name), strings.TrimSpace(ip)
}

func readJSONAsMap(path string) (map[string]any, error) {
	content, err := bos.ReadFile(path)
	if err != nil {
		return nil, err
	}

	decoded := map[string]any{}
	if err := json.Unmarshal(content, &decoded); err != nil {
		return nil, err
	}

	return decoded, nil
}

type cephOSDMapResult struct {
	Acting []int `json:"acting"`
	Up     []int `json:"up"`
}

func runSSHOnCephHost(ctx context.Context, hostIP, command string) string {
	homeDir, err := bos.UserHomeDir()
	Expect(err).ToNot(HaveOccurred())

	keyPath := filepath.Join(homeDir, ".ssh", "k2s", "id_rsa")
	_, err = bos.Stat(keyPath)
	Expect(err).ToNot(HaveOccurred(), "expected SSH key for k2s test user at '%s'", keyPath)

	remoteTarget := "remote@" + hostIP
	return suite.Cli("ssh.exe").MustExec(ctx,
		"-n",
		"-o", "StrictHostKeyChecking=no",
		"-i", keyPath,
		remoteTarget,
		command,
	)
}

func extractJSONBlob(output string) (string, error) {
	start := strings.Index(output, "{")
	end := strings.LastIndex(output, "}")
	if start < 0 || end < 0 || end < start {
		return "", fmt.Errorf("no JSON object found in output")
	}

	return output[start : end+1], nil
}

func countDistinctInts(values []int) int {
	seen := map[int]struct{}{}
	for _, v := range values {
		seen[v] = struct{}{}
	}

	return len(seen)
}
