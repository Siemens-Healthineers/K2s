// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"context"
	"testing"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

const (
	webAppPodName     = "web-app"
	myWebappNamespace = "my-webapp"
)

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestUpgradeValidation(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Upgrade User Application Validation Tests", Label("upgrade-user-application-validation"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
	k2s = dsl.NewK2s(suite)
})

var _ = Describe("Upgrade Validation", func() {
	Describe("Image Preservation", Label("upgrade-image-validation"), func() {

		It("user application images are preserved after upgrade", func(ctx SpecContext) {
			output := suite.K2sCli().RunOrFail(ctx, "image", "ls")

			expectedImages := map[string]string{
				"nginx": "latest",
				// Add other expected images here: "repository": "tag"
			}

			for repository, tag := range expectedImages {
				Expect(output).To(And(
					ContainSubstring(repository),
					ContainSubstring(tag),
				), "Image '%s:%s' is missing after upgrade", repository, tag)
			}
		})
	})

	Describe("Application Restoration", Label("upgrade-app-validation"), func() {

		It("my-webapp namespace contains web-app pod in running state", func(ctx SpecContext) {
			// This test should FAIL if resources are missing
			client := suite.Cluster().Client()
			clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
			Expect(err).To(BeNil(), "UPGRADE VALIDATION ERROR: Cannot access Kubernetes API after upgrade")

			// Check namespace exists
			_, err = clientSet.CoreV1().Namespaces().Get(ctx, myWebappNamespace, metav1.GetOptions{})
			Expect(err).To(BeNil(), "user namespace '%s' should be preserved after upgrade", myWebappNamespace)

			// List all pods in my-webapp namespace with label selector for web-app
			pods, err := clientSet.CoreV1().Pods(myWebappNamespace).List(ctx, metav1.ListOptions{
				LabelSelector: "app=" + webAppPodName,
			})
			Expect(err).NotTo(HaveOccurred(), "Cannot list pods in namespace '%s' after upgrade", myWebappNamespace)

			// Find web-app pods (deployment creates pods with generated names)
			Expect(len(pods.Items)).To(BeNumerically(">", 0),
				"expected to find pods with label 'app=%s' in namespace '%s'", webAppPodName, myWebappNamespace)

			// Check that at least one pod is running
			runningPods := 0
			for _, pod := range pods.Items {
				if pod.Status.Phase == corev1.PodRunning {
					runningPods++
				}
			}

			Expect(runningPods).To(BeNumerically(">", 0), "found pods for '%s', but none are in 'Running' state in namespace '%s'", webAppPodName, myWebappNamespace)
		})

		It("all user application pods are restored and running after upgrade", func(ctx SpecContext) {
			// Define namespaces where user applications are expected
			userNamespaces := []string{myWebappNamespace}

			for _, namespace := range userNamespaces {
				// Get client to query pods
				client := suite.Cluster().Client()
				clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
				Expect(err).To(BeNil())

				// First verify the namespace exists
				_, err = clientSet.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
				Expect(err).To(BeNil(), "namespace '%s' should exist after upgrade", namespace)

				// List all pods in namespace
				pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
				Expect(err).To(BeNil(), "cannot list pods in namespace '%s'", namespace)

				// Check that user pods are running
				for _, pod := range pods.Items {
					// User application pods should be running or succeeded
					Expect(pod.Status.Phase).To(BeElementOf(corev1.PodRunning, corev1.PodSucceeded),
						"pod '%s' in namespace '%s' is in state '%s', expected 'Running' or 'Succeeded'", pod.Name, namespace, pod.Status.Phase)
				}
			}
		})
	})

	Describe("Resource Validation", Label("upgrade-resource-validation"), func() {
		It("user deployments are preserved and available after upgrade", func(ctx SpecContext) {
			// This test should FAIL if expected user deployments don't exist
			userDeployments := map[string]string{
				webAppPodName: myWebappNamespace,
				// Add other expected deployments here
			}

			for deploymentName, namespace := range userDeployments {
				// Add custom error handling for better messages
				client := suite.Cluster().Client()
				clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
				Expect(err).To(BeNil())

				// Check if namespace exists first
				_, err = clientSet.CoreV1().Namespaces().Get(ctx, namespace, metav1.GetOptions{})
				Expect(err).To(BeNil(), "namespace '%s' for deployment '%s' not found", namespace, deploymentName)

				// Check if deployment exists
				_, err = clientSet.AppsV1().Deployments(namespace).Get(ctx, deploymentName, metav1.GetOptions{})
				Expect(err).To(BeNil(), "deployment '%s' not found in namespace '%s'", deploymentName, namespace)

				// Check if deployment is available
				suite.Cluster().ExpectDeploymentToBeAvailable(deploymentName, namespace)
			}
		})

		It("user services are preserved and accessible after upgrade", func(ctx SpecContext) {
			// This test should FAIL if expected user services don't exist
			client := suite.Cluster().Client()
			clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
			Expect(err).To(BeNil(), "UPGRADE VALIDATION ERROR: Cannot connect to Kubernetes API after upgrade")

			// Check that my-webapp namespace exists and has services
			_, err = clientSet.CoreV1().Namespaces().Get(ctx, myWebappNamespace, metav1.GetOptions{})
			Expect(err).To(BeNil(), "user namespace '%s' not found", myWebappNamespace)

			services, err := clientSet.CoreV1().Services(myWebappNamespace).List(ctx, metav1.ListOptions{})
			Expect(err).NotTo(HaveOccurred(), "Cannot list services in namespace '%s'", myWebappNamespace)

			// Expect at least one user service to exist
			Expect(len(services.Items)).To(BeNumerically(">", 0), "no services found in namespace '%s' after upgrade", myWebappNamespace)

			// Validate that services have proper configuration
			for _, service := range services.Items {
				Expect(service.Spec.ClusterIP).ToNot(BeEmpty(), "service '%s' is missing its ClusterIP", service.Name)
			}
		})
	})
})
