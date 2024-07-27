// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"

	c "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
)

func TestNetworkCheckerPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "networkchecker pkg Unit Tests", Label("unit", "ci", "status", "network", "networkchecker"))
}

var _ = Describe("NetworkChecker", func() {
	var (
		clientset *fake.Clientset
		k8sClient *c.K8sClientSet
		config    *rest.Config
	)

	BeforeEach(func() {
		clientset = fake.NewSimpleClientset()
		config = &rest.Config{}
		k8sClient = &c.K8sClientSet{
			Clientset: clientset,
			Config:    config,
		}

	})

	Describe("CreateNetworkCheckHandlers", func() {
		It("should create intra-node and inter-node handlers", func() {
			nodeGroups := map[string][]c.PodSpec{
				"node1": {
					{NodeName: "node1", DeploymentNameRef: "curl-1"},
					{NodeName: "node1", DeploymentNameRef: "app-1"},
				},
				"node2": {
					{NodeName: "node2", DeploymentNameRef: "curl-2"},
					{NodeName: "node2", DeploymentNameRef: "app-2"},
				},
			}

			handlers := networkchecker.CreateNetworkCheckHandlers(*k8sClient, nodeGroups)
			Expect(handlers).To(HaveLen(5)) // 2 intra-node + 3 inter-node checks
		})
	})

	Describe("CreateIntraNodeHandlers", func() {
		It("should create handlers for pods within the same node with only curl pods", func() {
			nodeGroups := map[string][]c.PodSpec{
				"node1": {
					{NodeName: "node1", DeploymentNameRef: "curl-1"},
					{NodeName: "node1", DeploymentNameRef: "app-1"},
				},
			}

			handlers := networkchecker.CreateIntraNodeHandlers(*k8sClient, nodeGroups)
			Expect(handlers).To(HaveLen(1))
		})
	})

	Describe("CreateInterNodeHandlers", func() {
		It("should create handlers for pods across different nodes", func() {
			nodeGroups := map[string][]c.PodSpec{
				"node1": {
					{NodeName: "node1", DeploymentNameRef: "curl-1"},
					{NodeName: "node1", DeploymentNameRef: "app-1"},
				},
				"node2": {
					{NodeName: "node2", DeploymentNameRef: "curl-2"},
					{NodeName: "node2", DeploymentNameRef: "app-2"},
				},
			}

			handlers := networkchecker.CreateInterNodeHandlers(*k8sClient, nodeGroups)
			Expect(handlers).To(HaveLen(3)) // 2 pods in node1 + 1 pod in node2 = 3 pairs
		})
	})
})
