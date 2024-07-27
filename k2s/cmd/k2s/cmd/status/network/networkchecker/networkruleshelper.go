// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package networkchecker

import (
	"os"
	"strings"

	c "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
)

const curlPodPrefix = "curl"

func CreateNetworkCheckHandlers(client c.K8sClientSet, nodeGroups map[string][]c.PodSpec) []ObservableNetworkChecker {

	networkCheckHandlers := CreateIntraNodeHandlers(client, nodeGroups)
	interNodeCheckHandlers := CreateInterNodeHandlers(client, nodeGroups)

	networkCheckHandlers = append(networkCheckHandlers, interNodeCheckHandlers...)

	return networkCheckHandlers
}

func CreateIntraNodeHandlers(client c.K8sClientSet, nodeGroups map[string][]c.PodSpec) []ObservableNetworkChecker {
	var networkCheckHandlers []ObservableNetworkChecker

	for _, pods := range nodeGroups {
		for firstPodIterator := 0; firstPodIterator < len(pods); firstPodIterator++ {
			for secondPodIterator := firstPodIterator + 1; secondPodIterator < len(pods); secondPodIterator++ {

				ok, pod1, pod2 := resolveCurlPod(pods[firstPodIterator], pods[secondPodIterator])
				if ok {
					handler := NewPodToPodWithinNodeHandler(client, pod1, pod2)
					networkCheckHandlers = append(networkCheckHandlers, handler)
				}
			}
		}
	}

	return networkCheckHandlers
}

func CreateInterNodeHandlers(client c.K8sClientSet, nodeGroups map[string][]c.PodSpec) []ObservableNetworkChecker {
	var networkCheckHandlers []ObservableNetworkChecker

	nodes := []string{}
	for nodeName := range nodeGroups {
		nodes = append(nodes, nodeName)
	}

	for firstNodeIterator := 0; firstNodeIterator < len(nodes); firstNodeIterator++ {
		for secondNodeIterator := firstNodeIterator + 1; secondNodeIterator < len(nodes); secondNodeIterator++ {
			node1Pods := nodeGroups[nodes[firstNodeIterator]]
			node2Pods := nodeGroups[nodes[secondNodeIterator]]

			for _, pod1 := range node1Pods {
				for _, pod2 := range node2Pods {

					ok, pod1, pod2 := resolveCurlPod(pod1, pod2)
					if ok {
						handler := NewPodToPodAcrossNodeHandler(client, pod1, pod2)
						networkCheckHandlers = append(networkCheckHandlers, handler)
					}
				}
			}
		}
	}

	return networkCheckHandlers
}

func resolveCurlPod(podSpec1, podSpec2 c.PodSpec) (ok bool, pod1, pod2 c.PodSpec) {

	hostName := getWinNodeName()

	if podSpec1.NodeName == hostName || strings.HasPrefix(podSpec1.DeploymentNameRef, curlPodPrefix) {
		// windows pods have curl, so nothing to do
		return true, podSpec1, podSpec2
	}

	if podSpec2.NodeName == hostName || strings.HasPrefix(podSpec2.DeploymentNameRef, curlPodPrefix) {
		return true, podSpec2, podSpec1
	}

	return false, podSpec1, podSpec2
}

func getWinNodeName() string {
	name, err := os.Hostname()
	if err != nil {
		return ""
	}
	return strings.ToLower(name)
}
