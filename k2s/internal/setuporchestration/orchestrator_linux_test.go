// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package setuporchestration

import (
	"reflect"
	"strings"
	"testing"

	"github.com/siemens-healthineers/k2s/internal/core/config"
)

func TestNodeNamesFromKubectlOutput(t *testing.T) {
	t.Parallel()

	actual := nodeNamesFromKubectlOutput("control-plane-1\ncontrol-plane-2\n")
	expected := []string{"control-plane-1", "control-plane-2"}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("nodeNamesFromKubectlOutput() = %v, want %v", actual, expected)
	}
}

func TestControlPlaneTaintJSONPathsUseEscapedNewlines(t *testing.T) {
	t.Parallel()

	for _, jsonPath := range []string{controlPlaneNodeNamesJSONPath, nodeTaintKeysJSONPath} {
		if strings.Contains(jsonPath, "\n") || !strings.Contains(jsonPath, `"\n"`) {
			t.Fatalf("JSONPath %q must contain an escaped newline literal", jsonPath)
		}
	}
}

func TestContainsNodeTaint(t *testing.T) {
	t.Parallel()

	const controlPlaneTaint = "node-role.kubernetes.io/control-plane"
	if !containsNodeTaint("node.kubernetes.io/not-ready\n"+controlPlaneTaint+"\n", controlPlaneTaint) {
		t.Fatal("containsNodeTaint() did not find the control-plane taint")
	}
	if containsNodeTaint("node.kubernetes.io/not-ready\n", controlPlaneTaint) {
		t.Fatal("containsNodeTaint() reported a missing control-plane taint")
	}
}

func TestCoreDNSZones(t *testing.T) {
	t.Parallel()

	corefile := `.:53 {
    forward . /etc/resolv.conf
}
cluster.local:53 {
    kubernetes cluster.local in-addr.arpa ip6.arpa {
        pods insecure
    }
}`
	actual := coreDNSZones(corefile)
	expected := []string{"cluster.local", "in-addr.arpa", "ip6.arpa"}
	if !reflect.DeepEqual(actual, expected) {
		t.Fatalf("coreDNSZones() = %v, want %v", actual, expected)
	}
}

func TestResolverIsImmutableFromOutput(t *testing.T) {
	t.Parallel()

	immutable, err := resolverIsImmutableFromOutput("----i--------- /etc/resolv.conf\n")
	if err != nil || !immutable {
		t.Fatalf("immutable resolver output = (%v, %v), want (true, nil)", immutable, err)
	}
	immutable, err = resolverIsImmutableFromOutput("-------------- /etc/resolv.conf\n")
	if err != nil || immutable {
		t.Fatalf("mutable resolver output = (%v, %v), want (false, nil)", immutable, err)
	}
	if _, err := resolverIsImmutableFromOutput(""); err == nil {
		t.Fatal("empty lsattr output returned nil error")
	}
}

func TestRenderClusterIPWebhookDeploymentUsesConfiguredPartitions(t *testing.T) {
	t.Parallel()

	manifest := "--linux-subnet=172.21.0.0/24\n--windows-subnet=172.21.1.0/24\n"
	rendered := renderClusterIPWebhookDeployment(manifest, config.ServiceCIDRConfig{
		LinuxCIDR:   "10.10.0.0/24",
		WindowsCIDR: "10.10.1.0/24",
	})
	if !strings.Contains(rendered, "--linux-subnet=10.10.0.0/24") || !strings.Contains(rendered, "--windows-subnet=10.10.1.0/24") {
		t.Fatalf("rendered webhook deployment did not contain configured CIDRs: %q", rendered)
	}
}
