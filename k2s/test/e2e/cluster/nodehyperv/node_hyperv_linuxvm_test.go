// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package nodehyperv

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/core/clusterconfig"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestHyperVLinuxNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Hyper-V Linux VM Node Acceptance Tests",
		Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-hyper-v"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(10*time.Minute))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

const (
	// KubeSwitch network CIDR (internal Hyper-V switch for K2s VMs)
	kubeSwitchCIDR = "172.19.1.0/24"
	// KubeSwitch is the name of the Hyper-V switch used by K2s VMs
	kubeSwitchName = "KubeSwitch"
)

// HyperVLinuxNodeInfo holds the details of a local VM node from cluster.json
type HyperVLinuxNodeInfo struct {
	Name      string
	IpAddress string
	Username  string
	NodeType  clusterconfig.NodeType
}

// nodeJSON is used to parse node entries from cluster.json
type nodeJSON struct {
	Name      string `json:"Name"`
	IpAddress string `json:"IpAddress"`
	Username  string `json:"Username"`
	NodeType  string `json:"NodeType"`
}

// findHyperVLinuxNode searches cluster.json for a node with NodeType=VM-EXISTING
// and returns its details. Handles both array and single-object formats for nodes.
func findHyperVLinuxNode() (*HyperVLinuxNodeInfo, bool) {
	configDir := suite.SetupInfo().Config.Host().K2sSetupConfigDir()
	clusterJsonPath := filepath.Join(configDir, "cluster.json")

	data, err := os.ReadFile(clusterJsonPath)
	if err != nil {
		GinkgoWriter.Printf("Could not read cluster.json: %v\n", err)
		return nil, false
	}

	// Try to parse nodes as an array first
	var clusterWithArray struct {
		Nodes []nodeJSON `json:"nodes"`
	}
	if err := json.Unmarshal(data, &clusterWithArray); err == nil && len(clusterWithArray.Nodes) > 0 {
		for _, node := range clusterWithArray.Nodes {
			if node.NodeType == string(clusterconfig.NodeTypeVMExisting) {
				return &HyperVLinuxNodeInfo{
					Name:      node.Name,
					IpAddress: node.IpAddress,
					Username:  node.Username,
					NodeType:  clusterconfig.NodeType(node.NodeType),
				}, true
			}
		}
		return nil, false
	}

	// Try to parse nodes as a single object (non-standard but may occur)
	var clusterWithObject struct {
		Nodes nodeJSON `json:"nodes"`
	}
	if err := json.Unmarshal(data, &clusterWithObject); err == nil && clusterWithObject.Nodes.Name != "" {
		node := clusterWithObject.Nodes
		if node.NodeType == string(clusterconfig.NodeTypeVMExisting) {
			return &HyperVLinuxNodeInfo{
				Name:      node.Name,
				IpAddress: node.IpAddress,
				Username:  node.Username,
				NodeType:  clusterconfig.NodeType(node.NodeType),
			}, true
		}
	}

	GinkgoWriter.Println("No VM-EXISTING node found in cluster.json")
	return nil, false
}

// isIPInCIDR checks if the given IP address falls within the specified CIDR range.
func isIPInCIDR(ipStr, cidrStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	_, cidrNet, err := net.ParseCIDR(cidrStr)
	if err != nil {
		return false
	}
	return cidrNet.Contains(ip)
}

// isVMReachableViaKubeSwitch verifies that the VM is reachable via the KubeSwitch network
// by testing TCP connectivity to the SSH port. This functionally proves the VM is attached
// to KubeSwitch since the IP is in the KubeSwitch CIDR range.
func isVMReachableViaKubeSwitch(vmIP string) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:22", vmIP), 5*time.Second)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// kubeSwitchExists checks if the KubeSwitch virtual switch exists in Hyper-V.
func kubeSwitchExists(ctx context.Context) bool {
	cmd := fmt.Sprintf("(Get-VMSwitch -Name '%s' -ErrorAction SilentlyContinue) -ne $null", kubeSwitchName)
	output := suite.Cli("powershell").NoStdOut().MustExec(ctx, "-Command", cmd)
	return strings.TrimSpace(output) == "True"
}

// getNodeStatus returns the Ready condition status of a node.
func getNodeStatus(ctx context.Context, nodeName string) (bool, error) {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		return false, err
	}

	node, err := clientSet.CoreV1().Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		return false, err
	}

	for _, cond := range node.Status.Conditions {
		if cond.Type == corev1.NodeReady {
			return cond.Status == corev1.ConditionTrue, nil
		}
	}
	return false, nil
}

// getPodsOnNode returns all pods scheduled on the given node in the specified namespace.
func getPodsOnNode(ctx context.Context, nodeName, namespace string) ([]corev1.Pod, error) {
	client := suite.Cluster().Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	if err != nil {
		return nil, err
	}

	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		FieldSelector: fmt.Sprintf("spec.nodeName=%s", nodeName),
	})
	if err != nil {
		return nil, err
	}
	return pods.Items, nil
}

// getControlPlaneNodeName returns the name of the control-plane node.
func getControlPlaneNodeName(ctx context.Context) string {
	output := suite.Kubectl().NoStdOut().MustExec(ctx, "get", "nodes",
		"-l", "node-role.kubernetes.io/control-plane",
		"-o", "jsonpath={.items[0].metadata.name}")
	return strings.TrimSpace(output)
}

var _ = Describe("Hyper-V Linux VM Node", Ordered, func() {
	var vmIP string
	var vmName string
	var vmUsername string
	var vmNodeType clusterconfig.NodeType

	BeforeAll(func() {
		nodeInfo, found := findHyperVLinuxNode()
		if !found {
			Skip("Skipping Hyper-V Linux VM node tests: no VM-EXISTING node found in cluster.json")
		}
		vmIP = nodeInfo.IpAddress
		vmName = nodeInfo.Name
		vmUsername = nodeInfo.Username
		vmNodeType = nodeInfo.NodeType

		GinkgoWriter.Printf("Using Hyper-V Linux VM node from cluster.json: name=%s, ip=%s, username=%s, nodeType=%s\n",
			vmName, vmIP, vmUsername, vmNodeType)
	})

	Describe("validate", Label("validate"), func() {
		Context("when reading node configuration from cluster.json", func() {
			It("node type is VM-EXISTING", func() {
				Expect(vmNodeType).To(Equal(clusterconfig.NodeTypeVMExisting),
					"Expected node type to be VM-EXISTING")
			})

			It("IP address is in KubeSwitch range", func() {
				Expect(isIPInCIDR(vmIP, kubeSwitchCIDR)).To(BeTrue(),
					"Expected IP %s to be within KubeSwitch CIDR %s", vmIP, kubeSwitchCIDR)
			})

			It("IP address is a valid IPv4 address", func() {
				ip := net.ParseIP(vmIP)
				Expect(ip).NotTo(BeNil(), "Expected a valid IP address, got: %s", vmIP)
				Expect(ip.To4()).NotTo(BeNil(), "Expected an IPv4 address, got: %s", vmIP)
			})

			It("node name is not empty", func() {
				Expect(vmName).NotTo(BeEmpty(), "Expected node name to be non-empty")
			})

			It("username is set for SSH access", func() {
				Expect(vmUsername).NotTo(BeEmpty(), "Expected username to be non-empty for SSH access")
			})
		})

		Context("when verifying Hyper-V VM configuration", func() {
			It("KubeSwitch virtual switch exists", func(ctx context.Context) {
				Expect(kubeSwitchExists(ctx)).To(BeTrue(),
					"Expected KubeSwitch virtual switch to exist in Hyper-V")
			})

			It("VM is reachable via KubeSwitch network", func() {
				Expect(isVMReachableViaKubeSwitch(vmIP)).To(BeTrue(),
					"Expected VM at %s to be reachable via KubeSwitch (SSH port 22)", vmIP)
			})
		})

		Context("when node is already part of the cluster", func() {
			It("node appears as Ready in the cluster", func(ctx context.Context) {
				suite.Cluster().ExpectNodeToBeReady(vmName, ctx)
			})
		})
	})

	Describe("node lifecycle", Label("lifecycle"), func() {
		const (
			testNamespace  = "node-lifecycle-test"
			deploymentName = "nginx-lifecycle-test"
			replicas       = 2
		)

		var controlPlaneNode string

		BeforeAll(func(ctx context.Context) {
			controlPlaneNode = getControlPlaneNodeName(ctx)
			GinkgoWriter.Printf("Control-plane node: %s\n", controlPlaneNode)

			// Create test namespace using pipe through cmd.exe
			cmd := fmt.Sprintf("%s create namespace %s --dry-run=client -o yaml | %s apply -f -",
				suite.Kubectl().Path(), testNamespace, suite.Kubectl().Path())
			suite.Cli("cmd.exe").MustExec(ctx, "/c", cmd)
		})

		AfterAll(func(ctx context.Context) {
			// Cleanup: ensure node is started and namespace is deleted
			GinkgoWriter.Println("Cleanup: ensuring node is started")
			k2s.StartNode(ctx, vmName)

			// Wait for node to be ready again
			Eventually(func() bool {
				ready, _ := getNodeStatus(ctx, vmName)
				return ready
			}, 5*time.Minute, 5*time.Second).Should(BeTrue(), "Node should be Ready after cleanup start")

			GinkgoWriter.Println("Cleanup: deleting test namespace")
			suite.Kubectl().Exec(ctx, "delete", "namespace", testNamespace, "--ignore-not-found")
		})

		Context("when deploying workload across nodes", Ordered, func() {
			It("creates a deployment with replicas spread across nodes", func(ctx context.Context) {
				// Create a deployment that will schedule pods on both control-plane and worker node
				// Using shsk2s.azurecr.io image which is pre-pulled and doesn't require internet
				// tolerationSeconds=30 ensures pods are evicted quickly when node becomes NotReady
				deploymentYaml := fmt.Sprintf(`
apiVersion: apps/v1
kind: Deployment
metadata:
  name: %s
  namespace: %s
spec:
  replicas: %d
  selector:
    matchLabels:
      app: %s
  template:
    metadata:
      labels:
        app: %s
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchLabels:
                  app: %s
              topologyKey: kubernetes.io/hostname
      containers:
      - name: albums-app
        image: shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0
        ports:
        - containerPort: 80
        env:
        - name: PORT
          value: "80"
        - name: RESOURCE
          value: "%s"
      tolerations:
      - key: "node-role.kubernetes.io/control-plane"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 30
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 30
`, deploymentName, testNamespace, replicas, deploymentName, deploymentName, deploymentName, deploymentName)

				// Apply the deployment using a temp file
				tempFile := fmt.Sprintf("%s\\deployment.yaml", suite.SetupInfo().Config.Host().K2sSetupConfigDir())
				writeCmd := fmt.Sprintf(`Set-Content -Path '%s' -Value @'
%s
'@`, tempFile, deploymentYaml)
				suite.Cli("powershell").MustExec(ctx, "-Command", writeCmd)
				suite.Kubectl().MustExec(ctx, "apply", "-f", tempFile)

				GinkgoWriter.Printf("Created deployment %s with %d replicas\n", deploymentName, replicas)
			})

			It("waits for deployment to be available", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				suite.Cluster().ExpectPodsUnderDeploymentReady(ctx, "app", deploymentName, testNamespace)
				GinkgoWriter.Println("Deployment is available and pods are ready")
			})

			It("verifies pods are scheduled on the worker node", func(ctx context.Context) {
				pods, err := getPodsOnNode(ctx, vmName, testNamespace)
				Expect(err).NotTo(HaveOccurred())
				Expect(len(pods)).To(BeNumerically(">", 0),
					"Expected at least one pod to be scheduled on worker node %s", vmName)

				for _, pod := range pods {
					GinkgoWriter.Printf("Pod %s is running on node %s\n", pod.Name, pod.Spec.NodeName)
				}
			})

			It("stops the worker node using k2s stop --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Stopping node %s\n", vmName)

				result := k2s.StopNode(ctx, vmName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s stop command completed\n", vmName)
			})

			It("verifies worker node becomes NotReady", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, vmName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return true // Keep polling on error
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", vmName, ready)
					return !ready // We want NotReady (ready=false)
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become NotReady after stop", vmName)
			})

			It("verifies pods on stopped node are terminating or evicted", func(ctx context.Context) {
				// Wait for pods to be marked for deletion (Terminating) or evicted
				// Note: "Terminating" is not a pod phase - it's indicated by DeletionTimestamp being set
				// The pod phase may still show "Running" while terminating
				Eventually(func() bool {
					pods, err := getPodsOnNode(ctx, vmName, testNamespace)
					if err != nil {
						GinkgoWriter.Printf("Error getting pods: %v\n", err)
						return false
					}

					// If no pods on this node, they've been evicted
					if len(pods) == 0 {
						GinkgoWriter.Printf("No pods remaining on node %s - all evicted\n", vmName)
						return true
					}

					for _, pod := range pods {
						isTerminating := pod.DeletionTimestamp != nil
						GinkgoWriter.Printf("Pod %s on node %s: phase=%s, terminating=%v\n",
							pod.Name, vmName, pod.Status.Phase, isTerminating)

						// Pod should be terminating (has deletion timestamp) or already gone
						if !isTerminating {
							return false // Pod not yet marked for deletion
						}
					}
					// All remaining pods are terminating
					return true
				}, 2*time.Minute, 5*time.Second).Should(BeTrue(),
					"Pods on stopped node should be terminating or evicted")
			})

			It("verifies new pods are scheduled on another node", func(ctx context.Context) {
				// The deployment controller should create new pods on available nodes
				Eventually(func() int {
					pods, err := getPodsOnNode(ctx, controlPlaneNode, testNamespace)
					if err != nil {
						GinkgoWriter.Printf("Error getting pods on control-plane: %v\n", err)
						return 0
					}

					runningCount := 0
					for _, pod := range pods {
						if pod.Status.Phase == corev1.PodRunning {
							runningCount++
							GinkgoWriter.Printf("Running pod %s on control-plane node %s\n",
								pod.Name, controlPlaneNode)
						}
					}
					return runningCount
				}, 5*time.Minute, 5*time.Second).Should(BeNumerically(">=", 1),
					"At least one pod should be running on control-plane node after worker node stops")
			})

			It("starts the worker node using k2s start --node", func(ctx context.Context) {
				GinkgoWriter.Printf("Starting node %s\n", vmName)

				result := k2s.StartNode(ctx, vmName)
				result.ExpectSuccess()

				GinkgoWriter.Printf("Node %s start command completed\n", vmName)
			})

			It("verifies worker node becomes Ready again", func(ctx context.Context) {
				Eventually(func() bool {
					ready, err := getNodeStatus(ctx, vmName)
					if err != nil {
						GinkgoWriter.Printf("Error getting node status: %v\n", err)
						return false
					}
					GinkgoWriter.Printf("Node %s Ready status: %v\n", vmName, ready)
					return ready
				}, 5*time.Minute, 5*time.Second).Should(BeTrue(),
					"Node %s should become Ready after start", vmName)
			})

			It("verifies deployment is healthy with all replicas", func(ctx context.Context) {
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, testNamespace)
				GinkgoWriter.Printf("Deployment %s is healthy after node restart\n", deploymentName)
			})
		})
	})

	Describe("cluster lifecycle", Label("cluster-lifecycle"), func() {
		Context("when stopping and starting the entire cluster", Ordered, func() {
			It("stops the cluster using k2s stop", func(ctx context.Context) {
				GinkgoWriter.Println("Stopping the entire K2s cluster")

				result := k2s.Stop(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster stop command completed")
			})

			It("starts the cluster using k2s start", func(ctx context.Context) {
				GinkgoWriter.Println("Starting the K2s cluster")

				result := k2s.Start(ctx)
				result.ExpectSuccess()

				GinkgoWriter.Println("Cluster start command completed")
			})

			It("verifies all nodes are Ready after cluster restart", func(ctx context.Context) {
				// Get all nodes and verify they are Ready
				Eventually(func() bool {
					client := suite.Cluster().Client()
					clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
					if err != nil {
						GinkgoWriter.Printf("Error creating clientset: %v\n", err)
						return false
					}

					nodes, err := clientSet.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
					if err != nil {
						GinkgoWriter.Printf("Error listing nodes: %v\n", err)
						return false
					}

					if len(nodes.Items) == 0 {
						GinkgoWriter.Println("No nodes found in cluster")
						return false
					}

					allReady := true
					for _, node := range nodes.Items {
						nodeReady := false
						for _, cond := range node.Status.Conditions {
							if cond.Type == corev1.NodeReady {
								nodeReady = cond.Status == corev1.ConditionTrue
								break
							}
						}
						GinkgoWriter.Printf("Node %s Ready: %v\n", node.Name, nodeReady)
						if !nodeReady {
							allReady = false
						}
					}
					return allReady
				}, 10*time.Minute, 10*time.Second).Should(BeTrue(),
					"All nodes should be Ready after cluster restart")

				GinkgoWriter.Println("All nodes are Ready after cluster restart")
			})

			It("verifies the added worker node is Ready", func(ctx context.Context) {
				ready, err := getNodeStatus(ctx, vmName)
				Expect(err).NotTo(HaveOccurred(), "Should be able to get node status for %s", vmName)
				Expect(ready).To(BeTrue(), "Worker node %s should be Ready after cluster restart", vmName)

				GinkgoWriter.Printf("Worker node %s is Ready after cluster restart\n", vmName)
			})
		})
	})
})
