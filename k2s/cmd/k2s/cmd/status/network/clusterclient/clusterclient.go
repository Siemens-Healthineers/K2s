// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package clusterclient

import (
	"context"
	"errors"
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/remotecommand"
)

type KubeConfigLoader func() (*rest.Config, error)

func NewDefaultK8sClient(kubeconfig string) (*K8sClientSet, error) {
	return NewK8sClient(func() (*rest.Config, error) {
		return DefaultConfigLoader(kubeconfig)
	})
}

func NewK8sClient(loader KubeConfigLoader) (*K8sClientSet, error) {
	config, err := loader()
	if err != nil {
		return nil, err
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}
	return &K8sClientSet{Clientset: clientset, Config: config}, nil
}

func DefaultConfigLoader(kubeconfig string) (*rest.Config, error) {
	return clientcmd.BuildConfigFromFlags("", kubeconfig)
}

func (k *K8sClientSet) WaitForDeploymentReady(namespace, deploymentName string) error {
	timeout := time.After(1 * time.Minute)    // Timeout after a minute
	ticker := time.NewTicker(5 * time.Second) // Check every 5 seconds
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			return errors.New("timed out waiting for deployment to be ready")
		case <-ticker.C:
			if checkDeploymentReady(*k, namespace, deploymentName) {
				return nil
			}
		}
	}
}

func (k *K8sClientSet) GetDeployments(namespace string) (DeploymentSpec, error) {
	deployments, err := k.Clientset.AppsV1().Deployments(namespace).List(context.TODO(), v1.ListOptions{})
	if err != nil {
		return DeploymentSpec{}, err
	}

	var items []DeploymentItem

	for _, deployment := range deployments.Items {
		pods, err := k.Clientset.CoreV1().Pods(namespace).List(context.TODO(), v1.ListOptions{
			LabelSelector: fmt.Sprintf("app=%s", deployment.Name)})
		if err != nil {
			// Handle error
			continue
		}

		var podSpecs []PodSpec
		for _, pod := range pods.Items {
			podSpecs = append(podSpecs, PodSpec{
				NodeName:          pod.Spec.NodeName,
				PodName:           pod.Name,
				Namespace:         pod.Namespace,
				DeploymentNameRef: deployment.Name,
			})
		}

		items = append(items, DeploymentItem{
			Name:     deployment.Name,
			PodSpecs: podSpecs,
		})
	}

	return DeploymentSpec{Items: items, Namespace: namespace}, nil
}

func (k *K8sClientSet) ExecuteCommand(param PodCmdExecParam) error {
	req := k.Clientset.CoreV1().RESTClient().Post().
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

	exec, err := remotecommand.NewSPDYExecutor(k.Config, "POST", req.URL())
	if err != nil {
		return err
	}

	return exec.StreamWithContext(context.TODO(), remotecommand.StreamOptions{
		Stdout: param.Stdout,
		Stderr: param.Stderr,
	})
}

func checkDeploymentReady(c K8sClientSet, namespace, deploymentName string) bool {
	pods, err := c.Clientset.CoreV1().Pods(namespace).List(context.TODO(), v1.ListOptions{
		LabelSelector: fmt.Sprintf("app=%s", deploymentName)})
	if err != nil {
		return false
	}

	// Check if there is at least one pod in the "Running" state.
	for _, pod := range pods.Items {
		if pod.Status.Phase == corev1.PodRunning || pod.Status.Phase == corev1.PodSucceeded {
			return true
		}
	}

	return false
}
