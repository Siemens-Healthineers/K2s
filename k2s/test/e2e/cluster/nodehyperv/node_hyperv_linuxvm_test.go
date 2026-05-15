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
)

var suite *framework.K2sTestSuite

func TestHyperVLinuxNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Hyper-V Linux VM Node Acceptance Tests",
		Label("core", "acceptance", "internet-required", "setup-required", "system-running", "node-hyper-v"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx,
		framework.SystemMustBeRunning,
		framework.ClusterTestStepPollInterval(500*time.Millisecond),
		framework.ClusterTestStepTimeout(20*time.Minute))

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
})
