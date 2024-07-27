// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package clusterclient_test

import (
	"context"
	"errors"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	clusterclient "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
	appsv1 "k8s.io/api/apps/v1"
	v1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"
)

func TestClusterClientPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "clusterclient pkg Unit Tests", Label("unit", "ci", "status", "network", "clusterclient"))
}

var _ = Describe("ClusterClient", func() {
	var (
		clientset *fake.Clientset
		k8sClient *clusterclient.K8sClientSet
		config    *rest.Config
	)

	BeforeEach(func() {
		clientset = fake.NewSimpleClientset()
		config = &rest.Config{}
		k8sClient = &clusterclient.K8sClientSet{
			Clientset: clientset,
			Config:    config,
		}
	})

	Describe("NewK8sClient", func() {
		It("should create a new Kubernetes client", func() {
			mockLoader := func() (*rest.Config, error) {
				return &rest.Config{}, nil
			}
			client, err := clusterclient.NewK8sClient(mockLoader)
			Expect(err).NotTo(HaveOccurred())
			Expect(client).NotTo(BeNil())
		})

		It("should return an error for invalid configuration", func() {
			mockLoader := func() (*rest.Config, error) {
				return nil, errors.New("invalid configuration")
			}
			client, err := clusterclient.NewK8sClient(mockLoader)
			Expect(err).To(HaveOccurred())
			Expect(client).To(BeNil())
		})
	})

	Describe("WaitForDeploymentReady", func() {
		It("should wait for deployment to be ready", func() {
			namespace := "default"
			deploymentName := "test-deployment"
			deployment := &appsv1.Deployment{
				ObjectMeta: metav1.ObjectMeta{
					Name:      deploymentName,
					Namespace: namespace,
				},
			}
			clientset.AppsV1().Deployments(namespace).Create(context.TODO(), deployment, metav1.CreateOptions{})
			go func() {
				time.Sleep(2 * time.Second)
				pod := &v1.Pod{
					ObjectMeta: metav1.ObjectMeta{
						Name:      "test-pod",
						Namespace: namespace,
						Labels: map[string]string{
							"app": deploymentName,
						},
					},
					Status: v1.PodStatus{
						Phase: v1.PodRunning,
					},
				}
				clientset.CoreV1().Pods(namespace).Create(context.TODO(), pod, metav1.CreateOptions{})
			}()
			err := k8sClient.WaitForDeploymentReady(namespace, deploymentName)
			Expect(err).NotTo(HaveOccurred())
		})
	})

	Describe("GetDeployments", func() {
		It("should get deployments in a namespace", func() {
			namespace := "default"
			deploymentName := "test-deployment"
			deployment := &appsv1.Deployment{
				ObjectMeta: metav1.ObjectMeta{
					Name:      deploymentName,
					Namespace: namespace,
				},
			}
			clientset.AppsV1().Deployments(namespace).Create(context.TODO(), deployment, metav1.CreateOptions{})
			deploymentSpec, err := k8sClient.GetDeployments(namespace)
			Expect(err).NotTo(HaveOccurred())
			Expect(deploymentSpec.Items).To(HaveLen(1))
			Expect(deploymentSpec.Items[0].Name).To(Equal(deploymentName))
		})
	})

	Describe("GroupPodsByNode", func() {
		It("should group pods by node", func() {
			deploymentItem := clusterclient.DeploymentItem{
				Name: "test-deployment",
				PodSpecs: []clusterclient.PodSpec{
					{
						NodeName: "node1",
						PodName:  "pod1",
					},
					{
						NodeName: "node2",
						PodName:  "pod2",
					},
					{
						NodeName: "node2",
						PodName:  "pod3",
					},
					{
						NodeName: "node2",
						PodName:  "pod4",
					},
				},
			}
			deploymentItems := []clusterclient.DeploymentItem{deploymentItem}
			nodeMap := clusterclient.GroupPodsByNode(deploymentItems)
			Expect(nodeMap).To(HaveLen(2))
			Expect(nodeMap["node1"]).To(HaveLen(1))
			Expect(nodeMap["node2"]).To(HaveLen(3))
		})
	})
})
