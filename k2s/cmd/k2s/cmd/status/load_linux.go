// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package status

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"os/exec"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
)

// LoadStatus gathers cluster status on Linux using kubectl directly,
// producing the same LoadedStatus shape as the Windows/PowerShell path.
func LoadStatus() (*LoadedStatus, error) {
	slog.Debug("[Status] Loading status via kubectl (Linux)")

	running := isAPIServerReachable()

	result := &LoadedStatus{
		CmdResult: common.CmdResult{},
		RunningState: &RunningState{
			IsRunning: running,
		},
	}

	if !running {
		result.RunningState.Issues = []string{"Kubernetes API server is not reachable"}
		return result, nil
	}

	// Gather nodes
	nodes, err := gatherNodes()
	if err != nil {
		slog.Warn("[Status] Could not gather node info", "error", err)
		result.RunningState.Issues = append(result.RunningState.Issues, fmt.Sprintf("cannot list nodes: %v", err))
	} else {
		result.Nodes = nodes
	}

	// Gather pods (all namespaces)
	pods, err := gatherPods()
	if err != nil {
		slog.Warn("[Status] Could not gather pod info", "error", err)
	} else {
		result.Pods = pods
	}

	// Gather version info
	versionInfo, err := gatherVersionInfo()
	if err != nil {
		slog.Warn("[Status] Could not gather version info", "error", err)
	} else {
		result.K8sVersionInfo = versionInfo
	}

	return result, nil
}

func isAPIServerReachable() bool {
	ctx := fmt.Sprintf("--request-timeout=%ds", 5)
	cmd := exec.Command("kubectl", "cluster-info", ctx)
	return cmd.Run() == nil
}

// kubectl JSON structures for nodes
type k8sNodeList struct {
	Items []k8sNode `json:"items"`
}

type k8sNode struct {
	Metadata struct {
		Name              string            `json:"name"`
		Labels            map[string]string `json:"labels"`
		CreationTimestamp  string            `json:"creationTimestamp"`
	} `json:"metadata"`
	Status struct {
		Conditions []struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		} `json:"conditions"`
		NodeInfo struct {
			KubeletVersion   string `json:"kubeletVersion"`
			KernelVersion    string `json:"kernelVersion"`
			OsImage          string `json:"osImage"`
			ContainerRuntime string `json:"containerRuntimeVersion"`
			OperatingSystem  string `json:"operatingSystem"`
		} `json:"nodeInfo"`
		Addresses []struct {
			Type    string `json:"type"`
			Address string `json:"address"`
		} `json:"addresses"`
		Capacity struct {
			CPU              string `json:"cpu"`
			EphemeralStorage string `json:"ephemeral-storage"`
			Memory           string `json:"memory"`
		} `json:"capacity"`
	} `json:"status"`
}

func gatherNodes() ([]Node, error) {
	output, err := exec.Command("kubectl", "get", "nodes", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get nodes: %w", err)
	}

	var nodeList k8sNodeList
	if err := json.Unmarshal(output, &nodeList); err != nil {
		return nil, fmt.Errorf("parsing node JSON: %w", err)
	}

	nodes := make([]Node, 0, len(nodeList.Items))
	for _, n := range nodeList.Items {
		node := Node{
			Name:             n.Metadata.Name,
			KubeletVersion:   n.Status.NodeInfo.KubeletVersion,
			KernelVersion:    n.Status.NodeInfo.KernelVersion,
			OsImage:          n.Status.NodeInfo.OsImage,
			ContainerRuntime: n.Status.NodeInfo.ContainerRuntime,
			Capacity: Capacity{
				Cpu:     n.Status.Capacity.CPU,
				Storage: n.Status.Capacity.EphemeralStorage,
				Memory:  n.Status.Capacity.Memory,
			},
		}

		// Determine role from labels
		for label := range n.Metadata.Labels {
			if strings.HasPrefix(label, "node-role.kubernetes.io/") {
				node.Role = strings.TrimPrefix(label, "node-role.kubernetes.io/")
				break
			}
		}

		// Determine Ready status
		for _, cond := range n.Status.Conditions {
			if cond.Type == "Ready" {
				node.IsReady = cond.Status == "True"
				if node.IsReady {
					node.Status = "Ready"
				} else {
					node.Status = "NotReady"
				}
				break
			}
		}

		// Get internal IP
		for _, addr := range n.Status.Addresses {
			if addr.Type == "InternalIP" {
				node.InternalIp = addr.Address
				break
			}
		}

		// Compute age
		if n.Metadata.CreationTimestamp != "" {
			if created, err := time.Parse(time.RFC3339, n.Metadata.CreationTimestamp); err == nil {
				node.Age = formatAge(time.Since(created))
			}
		}

		nodes = append(nodes, node)
	}

	return nodes, nil
}

// kubectl JSON structures for pods
type k8sPodList struct {
	Items []k8sPod `json:"items"`
}

type k8sPod struct {
	Metadata struct {
		Name              string `json:"name"`
		Namespace         string `json:"namespace"`
		CreationTimestamp  string `json:"creationTimestamp"`
	} `json:"metadata"`
	Spec struct {
		NodeName string `json:"nodeName"`
	} `json:"spec"`
	Status struct {
		Phase  string `json:"phase"`
		PodIP  string `json:"podIP"`
		ContainerStatuses []struct {
			Ready        bool  `json:"ready"`
			RestartCount int   `json:"restartCount"`
		} `json:"containerStatuses"`
	} `json:"status"`
}

func gatherPods() ([]Pod, error) {
	output, err := exec.Command("kubectl", "get", "pods", "--all-namespaces", "-o", "json").Output()
	if err != nil {
		return nil, fmt.Errorf("kubectl get pods: %w", err)
	}

	var podList k8sPodList
	if err := json.Unmarshal(output, &podList); err != nil {
		return nil, fmt.Errorf("parsing pod JSON: %w", err)
	}

	pods := make([]Pod, 0, len(podList.Items))
	for _, p := range podList.Items {
		pod := Pod{
			Name:      p.Metadata.Name,
			Namespace: p.Metadata.Namespace,
			Status:    p.Status.Phase,
			Ip:        p.Status.PodIP,
			Node:      p.Spec.NodeName,
			IsRunning: p.Status.Phase == "Running",
		}

		// Compute ready fraction and restarts
		totalContainers := len(p.Status.ContainerStatuses)
		readyContainers := 0
		totalRestarts := 0
		for _, cs := range p.Status.ContainerStatuses {
			if cs.Ready {
				readyContainers++
			}
			totalRestarts += cs.RestartCount
		}
		pod.Ready = fmt.Sprintf("%d/%d", readyContainers, totalContainers)
		pod.Restarts = fmt.Sprintf("%d", totalRestarts)

		// Compute age
		if p.Metadata.CreationTimestamp != "" {
			if created, err := time.Parse(time.RFC3339, p.Metadata.CreationTimestamp); err == nil {
				pod.Age = formatAge(time.Since(created))
			}
		}

		pods = append(pods, pod)
	}

	return pods, nil
}

func gatherVersionInfo() (*K8sVersionInfo, error) {
	info := &K8sVersionInfo{}

	if output, err := exec.Command("kubectl", "version", "--client", "-o", "json").Output(); err == nil {
		var v struct {
			ClientVersion struct {
				GitVersion string `json:"gitVersion"`
			} `json:"clientVersion"`
		}
		if json.Unmarshal(output, &v) == nil {
			info.K8sClientVersion = v.ClientVersion.GitVersion
		}
	}

	if output, err := exec.Command("kubectl", "version", "-o", "json").Output(); err == nil {
		var v struct {
			ServerVersion struct {
				GitVersion string `json:"gitVersion"`
			} `json:"serverVersion"`
		}
		if json.Unmarshal(output, &v) == nil {
			info.K8sServerVersion = v.ServerVersion.GitVersion
		}
	}

	return info, nil
}

func formatAge(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%ds", int(d.Seconds()))
	}
	if d < time.Hour {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	if d < 24*time.Hour {
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	days := int(d.Hours() / 24)
	return fmt.Sprintf("%dd", days)
}
