// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package k8s

import (
	"bytes"
	"context"
	"fmt"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"

	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/remotecommand"

	//lint:ignore ST1001 test framework code

	. "github.com/onsi/ginkgo/v2"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"sigs.k8s.io/e2e-framework/klient"
	"sigs.k8s.io/e2e-framework/klient/conf"
	k8sklient "sigs.k8s.io/e2e-framework/klient/k8s"
	"sigs.k8s.io/e2e-framework/klient/wait"
	"sigs.k8s.io/e2e-framework/klient/wait/conditions"
	"sigs.k8s.io/e2e-framework/pkg/envconf"
)

type Cluster struct {
	*envconf.Config
	testStepTimeout      time.Duration
	testStepPollInterval time.Duration
}

type podExecParam struct {
	Namespace string
	Pod       string
	Container string
	Command   []string
	Config    *rest.Config
	Ctx       context.Context
	Stdout    *bytes.Buffer
	Stderr    *bytes.Buffer
}

func NewCluster(testStepTimeout time.Duration, testStepPollInterval time.Duration) *Cluster {
	configFilePath := conf.ResolveKubeConfigFile()
	kubeConfig := envconf.NewWithKubeConfig(configFilePath)

	return &Cluster{
		Config:               kubeConfig,
		testStepTimeout:      testStepTimeout,
		testStepPollInterval: testStepPollInterval,
	}
}

func (c *Cluster) ExpectDeploymentToBeAvailable(name string, namespace string) {
	dep := appsv1.Deployment{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace},
	}

	condition := conditions.New(c.Client().Resources()).DeploymentConditionMatch(&dep, appsv1.DeploymentAvailable, corev1.ConditionTrue)

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectDeploymentToBeRemoved(ctx context.Context, labelName string, deploymentName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	areAllContainersExited := func() (bool, error) {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: fmt.Sprintf("%s=%s", labelName, deploymentName)})
		if err != nil {
			return false, err
		}

		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			for _, container := range pod.Status.ContainerStatuses {
				GinkgoWriter.Println("Container name:", container.Name, "| Container Status:", container.State)
				// Check if the container has terminated
				if container.State.Terminated == nil {
					GinkgoWriter.Println("Waiting for all containers to exit...")
					return false, nil
				}
			}
		}
		return true, nil
	}

	Eventually(areAllContainersExited, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())

	IsDeploymentAvailable := func() (bool, error) {
		deploymentsClient := clientSet.AppsV1().Deployments(namespace)

		deploymentList, err := deploymentsClient.List(ctx, metav1.ListOptions{})
		Expect(err).To(BeNil())

		for _, deployment := range deploymentList.Items {
			if deployment.Name == deploymentName {
				return true, nil
			}
		}

		return false, nil
	}

	Eventually(areAllContainersExited, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
	Eventually(IsDeploymentAvailable, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeFalse())
}

func (c *Cluster) ExpectDeploymentToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

func (c *Cluster) ExpectDeploymentToBeReachableFromPodOfOtherDeploymentAtPort(targetName string, targetNamespace string, sourceName string, sourceNamespace string, port string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local:" + port + "/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

func (c *Cluster) ExpectDeploymentNotToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer
	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetName + "." + targetNamespace + ".svc.cluster.local/" + targetName}

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       pod.Name,
		Container: sourceName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToBeForbidden(param)
}

func (c *Cluster) ExpectStatefulSetToBeReady(name string, namespace string, expectedReplicas int32, ctx context.Context) {
	statefulSet := appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceMatch(&statefulSet, func(object k8sklient.Object) bool {
		set := object.(*appsv1.StatefulSet)

		return set.Status.AvailableReplicas == expectedReplicas && set.Status.ReadyReplicas == expectedReplicas
	})

	GinkgoWriter.Println("Waiting for StatefulSet <", name, "> to be ready..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("StatefulSet <", name, "> ready.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).PodReady(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of StatefulSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod ready")

			condition = conditions.New(resources).ContainersReady(&pod)

			GinkgoWriter.Println("Waiting for containers of Pod <", pod.Name, "> of StatefulSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Containers ready")
		}
	}
}

func (c *Cluster) ExpectPersistentVolumeToBeBound(name string, namespace string, expectedPVClaims int32, ctx context.Context) {
	var pvcList corev1.PersistentVolumeClaimList
	err := c.Client().Resources(namespace).List(ctx, &pvcList)
	Expect(err).ToNot(HaveOccurred(), "failed to list PVCs in namespace %s", namespace)

	Expect(len(pvcList.Items)).To(Equal(int(expectedPVClaims)), "expected exactly %d PVC in namespace %s, found %d", expectedPVClaims, namespace, len(pvcList.Items))

	pvc := pvcList.Items[0]
	Expect(pvc.Name).To(Equal(name), "the only PVC in namespace %s should be %s", namespace, name)

	condition := conditions.New(c.Client().Resources(namespace)).ResourceMatch(&pvc, func(object k8sklient.Object) bool {
		foundPVC := object.(*corev1.PersistentVolumeClaim)
		return foundPVC.Status.Phase == corev1.ClaimBound
	})

	GinkgoWriter.Println("Waiting for PersistentVolumeClaim <", name, "> to be bound..")
	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectStatefulSetToBeDeleted(name string, namespace string, ctx context.Context) {
	statefulSet := appsv1.StatefulSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceDeleted(&statefulSet)

	GinkgoWriter.Println("Waiting for StatefulSet <", name, "> to be deleted..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("StatefulSet <", name, "> deleted.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).ResourceDeleted(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of StatefulSet <", name, "> to be deleted..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod deleted")
		}
	}
}

func (c *Cluster) ExpectDaemonSetToBeReady(name string, namespace string, expectedNumber int32, ctx context.Context) {
	daemonSet := appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceMatch(&daemonSet, func(object k8sklient.Object) bool {
		set := object.(*appsv1.DaemonSet)

		return set.Status.NumberAvailable == expectedNumber && set.Status.NumberReady == expectedNumber
	})

	GinkgoWriter.Println("Waiting for DaemonSet <", name, "> to be ready..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("DaemonSet <", name, "> ready.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).PodReady(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of DaemonSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod ready")

			condition = conditions.New(resources).ContainersReady(&pod)

			GinkgoWriter.Println("Waiting for containers of Pod <", pod.Name, "> of DaemonSet <", name, "> to be ready..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Containers ready")
		}
	}
}

func (c *Cluster) ExpectDaemonSetToBeDeleted(name string, namespace string, ctx context.Context) {
	daemonSet := appsv1.DaemonSet{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	resources := c.Client().Resources(namespace)

	condition := conditions.New(resources).ResourceDeleted(&daemonSet)

	GinkgoWriter.Println("Waiting for DaemonSet <", name, "> to be deleted..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("DaemonSet <", name, "> deleted.")

	pods := &corev1.PodList{}

	GinkgoWriter.Println("Retrieving all Pods of namespace <", namespace, ">..")

	Expect(resources.List(ctx, pods)).To(Succeed())

	GinkgoWriter.Println("Found <", len(pods.Items), "> Pod(s).")

	for _, pod := range pods.Items {
		if len(pod.OwnerReferences) > 0 && pod.OwnerReferences[0].Name == name {
			condition := conditions.New(resources).ResourceDeleted(&pod)

			GinkgoWriter.Println("Waiting for Pod <", pod.Name, "> of DaemonSet <", name, "> to be deleted..")

			Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

			GinkgoWriter.Println("Pod deleted")
		}
	}
}

func (c *Cluster) ExpectPodOfDeploymentToBeReachableFromPodOfOtherDeployment(targetName string, targetNamespace string, sourceName string, sourceNamespace string, ctx context.Context) {
	client := c.Client()

	sourcePod, err := determineFirstPodOfDeployment(sourceName, sourceNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	targetPod, err := determineFirstPodOfDeployment(targetName, targetNamespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	var stdout, stderr bytes.Buffer

	param := podExecParam{
		Namespace: sourceNamespace,
		Pod:       sourcePod.Name,
		Container: sourceName,
		Command:   []string{"curl", "-i", "-m", "10", "--retry", "3", "http://" + targetPod.Status.PodIP + "/" + targetName},
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

// This is used when cluster restart is performed to ensure all system pods are up and running
func (c *Cluster) ExpectClusterIsRunningAfterRestart(ctx context.Context) {
	// Run the check 5 times with a 5-second interval to ensure cluster has started
	for i := 0; i < 5; i++ {
		GinkgoWriter.Println("************************Iteration:", i+1, "************************")
		if c.AreAllPodsReady(ctx, "kube-system") {
			GinkgoWriter.Println("Iteration:", i+1, "kube-system pods are ready")
		} else {
			GinkgoWriter.Println("Iteration:", i+1, "kube-system pods are not ready")
		}

		if c.AreAllPodsReady(ctx, "kube-flannel") {
			GinkgoWriter.Println("Iteration:", i+1, "kube-flannel pods are ready")
		} else {
			GinkgoWriter.Println("Iteration:", i+1, "kube-flannel pods are not ready")
		}

		// Wait for 5 seconds before the next check
		time.Sleep(5 * time.Second)
	}
	Expect(c.AreAllPodsReady(ctx, "kube-system")).To(BeTrue())
	Expect(c.AreAllPodsReady(ctx, "kube-flannel")).To(BeTrue())
}

// This is used to check system pods are up and running, use EnsureClusterIsRunningAfterRestart if the check is needed after restart
func (c *Cluster) ExpectClusterIsRunning(ctx context.Context) {
	Eventually(c.AreAllPodsReady(ctx, "kube-system"), c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(), "Not all pods are ready in namespace: kube-system")
	Eventually(c.AreAllPodsReady(ctx, "kube-flannel"), c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue(), "Not all pods are ready in namespace: kube-flannel")
}

func (c *Cluster) AreAllPodsReady(ctx context.Context, namespace string) bool {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())
	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		GinkgoT().Logf("Error listing pods in %s namespace: %v", namespace, err)
		return false
	}

	for _, pod := range pods.Items {
		GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s Status: %-40s", pod.Name, pod.Status.Phase))

		// Check if the pod is in the "Running" phase
		if pod.Status.Phase != "Running" {
			GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s is not Running yet", pod.Name))
			return false
		}

		for _, condition := range pod.Status.Conditions {
			if condition.Type == corev1.PodReady && condition.Status != corev1.ConditionTrue {
				GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s is not ready yet Condition Type: %s Condition Status: %s Last Transition Time: %s", pod.Name, condition.Type, condition.Status, condition.LastTransitionTime))
				return false
			}

			if condition.Type == corev1.ContainersReady && condition.Status != corev1.ConditionTrue {
				GinkgoWriter.Println(fmt.Sprintf("Pod: %-40s containers are not ready yet Condition Type: %s Condition Status: %s Last Transition Time: %s", pod.Name, condition.Type, condition.Status, condition.LastTransitionTime))
				return false
			}
		}

		// Check if all containers in the pod are ready
		for _, containerStatus := range pod.Status.ContainerStatuses {
			if !containerStatus.Ready {
				GinkgoWriter.Println(fmt.Sprintf("Pod Container: %-40s is not Running yet", pod.Name))
				return false
			}
		}
	}

	return true
}

func (c *Cluster) ExpectPodToBeReady(name string, namespace string, hostname string) {
	nameToUse := strings.Replace(name, "HOSTNAME_PLACEHOLDER", hostname, -1)
	namespaceToUse := strings.Replace(namespace, "HOSTNAME_PLACEHOLDER", hostname, -1)

	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: nameToUse, Namespace: namespaceToUse}}

	condition := conditions.New(c.Client().Resources()).PodReady(pod)

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())
}

func (c *Cluster) ExpectPodToBeCompleted(name string, namespace string) {
	pod := &corev1.Pod{ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: namespace}}

	condition := conditions.New(c.Client().Resources(namespace)).ResourceMatch(pod, func(object k8sklient.Object) bool {
		foundPod := object.(*corev1.Pod)

		statuses := foundPod.Status.ContainerStatuses
		if len(statuses) != 1 {
			return false
		}

		terminated := statuses[0].State.Terminated
		if terminated == nil {
			return false
		}

		return terminated.ExitCode == 0
	})

	GinkgoWriter.Println("Waiting for container in Pod <", name, "> (namespace ", namespace, ">) to exit with exit code zero..")

	Expect(wait.For(condition, c.waitOptions()...)).To(Succeed())

	GinkgoWriter.Println("Pod <", name, "> completed")
}

func (c *Cluster) ExpectPodsUnderDeploymentReady(ctx context.Context, labelName string, deploymentName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	Eventually(func() bool {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: fmt.Sprintf("%s=%s", labelName, deploymentName)})
		if err != nil {
			return false
		}

		// Check if there is at least one pod in the "Running" state.
		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			if pod.Status.Phase == corev1.PodRunning || pod.Status.Phase == corev1.PodSucceeded {
				GinkgoWriter.Println("At least one pod is running in the deployment:", deploymentName)
				return true
			}
		}

		GinkgoWriter.Println("Waiting for a pod with label name:", labelName, "label value:",
			deploymentName, "namespace", namespace, "to become ready...")
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
}

func (c *Cluster) ExpectPodsInReadyState(ctx context.Context, labelName string, namespace string) {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	Eventually(func() bool {
		pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
			LabelSelector: labelName})
		if err != nil {
			return false
		}

		// Check if there is at least one pod in the "Running" state.
		for _, pod := range pods.Items {
			GinkgoWriter.Println("Pod name:", pod.Name, "| Pod Status:", pod.Status.Phase)
			if pod.Status.Phase == corev1.PodRunning || pod.Status.Phase == corev1.PodSucceeded {
				return true
			}
		}

		GinkgoWriter.Println("Waiting for a pod with label name:", labelName, "label value:",
			namespace, "to become ready...")
		return false
	}, c.testStepTimeout, c.testStepPollInterval, ctx).Should(BeTrue())
}

func (c *Cluster) ExpectNodeToBeReady(name string, ctx context.Context) {
	var node corev1.Node

	Expect(c.Client().Resources().Get(ctx, name, "", &node)).To(Succeed())

	GinkgoWriter.Println("Node <", node.Name, "> found")

	Expect(isNodeReady(node)).To(BeTrue())
}

func (c *Cluster) ExpectInternetToBeReachableFromPodOfDeployment(deploymentName string, namespace string, proxy string, ctx context.Context) {
	client := c.Client()

	pod, err := determineFirstPodOfDeployment(deploymentName, namespace, client, ctx)

	Expect(err).ShouldNot(HaveOccurred())

	command := []string{"curl", "-i", "-m", "10", "--retry", "3", "--insecure", "www.msftconnecttest.com/connecttest.txt"}
	if proxy != "" {
		GinkgoWriter.Println("Using proxy for curl")

		command = []string{"curl", "-i", "-m", "10", "--retry", "3", "--insecure", "-x", proxy, "www.msftconnecttest.com/connecttest.txt"}
	}

	var stdout, stderr bytes.Buffer

	GinkgoWriter.Println("Executing command <", command, "> ..")

	param := podExecParam{
		Namespace: namespace,
		Pod:       pod.Name,
		Container: deploymentName,
		Command:   command,
		Config:    client.Resources().GetConfig(),
		Ctx:       ctx,
		Stdout:    &stdout,
		Stderr:    &stderr,
	}

	expectCmdExecInPodToSucceed(param)
}

func (c *Cluster) waitOptions() []wait.Option {
	return []wait.Option{wait.WithTimeout(c.testStepTimeout), wait.WithInterval(c.testStepPollInterval), wait.WithImmediate()}
}

func determineFirstPodOfDeployment(deploymentName string, namespace string, client klient.Client, ctx context.Context) (*corev1.Pod, error) {
	pods := &corev1.PodList{}

	err := client.Resources(namespace).List(ctx, pods)
	if err != nil {
		return nil, err
	}
	if pods.Items == nil {
		return nil, fmt.Errorf("no matching Pod found for Deployment '%s' in namespace '%s'", namespace, deploymentName)
	}

	for _, pod := range pods.Items {
		if strings.Contains(pod.Name, deploymentName) {
			GinkgoWriter.Println("Pod <", pod.Name, "> in namespace <", namespace, "> found for Deployment <", deploymentName, ">")
			return &pod, nil
		}
	}

	return nil, fmt.Errorf("no matching Pod found for Deployment '%s' in namespace '%s'", namespace, deploymentName)
}

func contains(slice []string, item string) bool {
	for _, v := range slice {
		if v == item {
			return true
		}
	}
	return false
}

func (c *Cluster) GetPodsGroupedByNode(ctx context.Context, namespace string, nodes []string) map[string][]corev1.Pod {
	client := c.Client()
	clientSet, err := kubernetes.NewForConfig(client.Resources().GetConfig())
	Expect(err).To(BeNil())

	pods, err := clientSet.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	Expect(err).NotTo(HaveOccurred(), "Failed to fetch pods")

	podsByNode := make(map[string][]corev1.Pod)
	for _, pod := range pods.Items {
		if contains(nodes, pod.Spec.NodeName) {
			podsByNode[pod.Spec.NodeName] = append(podsByNode[pod.Spec.NodeName], pod)
		}
	}
	return podsByNode
}

func expectCmdExecInPodToSucceed(param podExecParam) {
	Expect(executeCommandInPod(param)).To(Succeed())

	httpStatus := strings.Split(param.Stdout.String(), "\n")[0]

	GinkgoWriter.Println("Command <", param.Command, "> executed with http status <", httpStatus, ">")

	Expect(httpStatus).To(ContainSubstring("200"))
}

func expectCmdExecInPodToBeForbidden(param podExecParam) {
	Expect(executeCommandInPod(param)).To(Succeed())

	httpStatus := strings.Split(param.Stdout.String(), "\n")[0]

	GinkgoWriter.Println("Command <", param.Command, "> executed with http status <", httpStatus, ">")

	//403 is http status forbidden
	Expect(httpStatus).To(ContainSubstring("403"))
}

func executeCommandInPod(param podExecParam) error {
	clientSet, err := kubernetes.NewForConfig(param.Config)
	if err != nil {
		return err
	}

	req := clientSet.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(param.Pod).
		Namespace(param.Namespace).
		SubResource("exec")

	newScheme := runtime.NewScheme()
	if err := corev1.AddToScheme(newScheme); err != nil {
		return err
	}

	parameterCodec := runtime.NewParameterCodec(newScheme)
	req.VersionedParams(&corev1.PodExecOptions{
		Container: param.Container,
		Command:   param.Command,
		Stdout:    true,
		Stderr:    true,
	}, parameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(param.Config, "POST", req.URL())
	if err != nil {
		return err
	}

	return exec.StreamWithContext(param.Ctx, remotecommand.StreamOptions{
		Stdout: param.Stdout,
		Stderr: param.Stderr,
	})
}

func isNodeReady(node corev1.Node) bool {
	for _, cond := range node.Status.Conditions {
		if cond.Type == "Ready" && cond.Status == "True" {
			return true
		}
	}

	return false
}
