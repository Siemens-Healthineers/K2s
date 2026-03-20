// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestNewIPAllocator(t *testing.T) {
	alloc, err := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if alloc.linuxStart.String() != "172.21.0.50" {
		t.Errorf("linux start = %s, want 172.21.0.50", alloc.linuxStart)
	}
	if alloc.linuxEnd.String() != "172.21.0.254" {
		t.Errorf("linux end = %s, want 172.21.0.254", alloc.linuxEnd)
	}
	if alloc.windowsStart.String() != "172.21.1.50" {
		t.Errorf("windows start = %s, want 172.21.1.50", alloc.windowsStart)
	}
	if alloc.windowsEnd.String() != "172.21.1.254" {
		t.Errorf("windows end = %s, want 172.21.1.254", alloc.windowsEnd)
	}
}

func TestNewIPAllocatorInvalidCIDR(t *testing.T) {
	_, err := NewIPAllocator("invalid", "172.21.1.0/24", 50)
	if err == nil {
		t.Fatal("expected error for invalid CIDR")
	}
}

func TestNewIPAllocatorSubnetTooSmall(t *testing.T) {
	_, err := NewIPAllocator("172.21.0.0/30", "172.21.1.0/24", 50)
	if err == nil {
		t.Fatal("expected error for subnet too small")
	}
}

func TestAllocateIPLinuxFirstFree(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.50" {
		t.Errorf("got %s, want 172.21.0.50", ip)
	}
}

func TestAllocateIPWindowsFirstFree(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("windows", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.1.50" {
		t.Errorf("got %s, want 172.21.1.50", ip)
	}
}

func TestAllocateIPSkipsUsed(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{
		"172.21.0.50": true,
		"172.21.0.51": true,
		"172.21.0.52": true,
	}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.53" {
		t.Errorf("got %s, want 172.21.0.53", ip)
	}
}

func TestAllocateIPWindowsSkipsUsed(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{
		"172.21.1.50": true,
	}

	ip, err := alloc.AllocateIP("windows", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.1.51" {
		t.Errorf("got %s, want 172.21.1.51", ip)
	}
}

func TestAllocateIPExhausted(t *testing.T) {
	// Use a very small subnet (172.21.0.0/30 = 4 IPs: .0, .1, .2, .3)
	// With 1 reserved IP, range is .1 to .2 (broadcast .3 excluded)
	alloc, _ := NewIPAllocator("172.21.0.0/30", "172.21.1.0/24", 1)
	usedIPs := map[string]bool{
		"172.21.0.1": true,
		"172.21.0.2": true,
	}

	_, err := alloc.AllocateIP("linux", usedIPs)
	if err == nil {
		t.Fatal("expected error when all IPs are exhausted")
	}
}

func TestAllocateIPDefaultsToLinux(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)
	usedIPs := map[string]bool{}

	ip, err := alloc.AllocateIP("", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.50" {
		t.Errorf("got %s, want 172.21.0.50 (should default to linux)", ip)
	}
}

func TestAllocateIPCanUseLastIP(t *testing.T) {
	alloc, _ := NewIPAllocator("172.21.0.0/24", "172.21.1.0/24", 50)

	// Mark all IPs except .254 as used
	usedIPs := map[string]bool{}
	for i := 50; i < 254; i++ {
		usedIPs["172.21.0."+itoa(i)] = true
	}

	ip, err := alloc.AllocateIP("linux", usedIPs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip != "172.21.0.254" {
		t.Errorf("got %s, want 172.21.0.254", ip)
	}
}

func TestSubnetRange(t *testing.T) {
	tests := []struct {
		cidr       string
		reserved   int
		wantStart  string
		wantEnd    string
		wantErr    bool
	}{
		{"172.21.0.0/24", 50, "172.21.0.50", "172.21.0.254", false},
		{"172.21.1.0/24", 50, "172.21.1.50", "172.21.1.254", false},
		{"10.0.0.0/24", 10, "10.0.0.10", "10.0.0.254", false},
		{"172.21.0.0/30", 1, "172.21.0.1", "172.21.0.2", false},
		{"172.21.0.0/30", 50, "", "", true}, // too small
	}

	for _, tt := range tests {
		start, end, err := subnetRange(tt.cidr, tt.reserved)
		if tt.wantErr {
			if err == nil {
				t.Errorf("subnetRange(%s, %d): expected error", tt.cidr, tt.reserved)
			}
			continue
		}
		if err != nil {
			t.Errorf("subnetRange(%s, %d): unexpected error: %v", tt.cidr, tt.reserved, err)
			continue
		}
		if start.String() != tt.wantStart {
			t.Errorf("subnetRange(%s, %d): start = %s, want %s", tt.cidr, tt.reserved, start, tt.wantStart)
		}
		if end.String() != tt.wantEnd {
			t.Errorf("subnetRange(%s, %d): end = %s, want %s", tt.cidr, tt.reserved, end, tt.wantEnd)
		}
	}
}

func TestIncAndDecIP(t *testing.T) {
	ip := dupIP([]byte{172, 21, 0, 254})
	incIP(ip)
	if ip.String() != "172.21.0.255" {
		t.Errorf("inc 172.21.0.254 = %s, want 172.21.0.255", ip)
	}

	ip2 := dupIP([]byte{172, 21, 0, 255})
	incIP(ip2)
	if ip2.String() != "172.21.1.0" {
		t.Errorf("inc 172.21.0.255 = %s, want 172.21.1.0", ip2)
	}

	ip3 := dupIP([]byte{172, 21, 1, 0})
	decIP(ip3)
	if ip3.String() != "172.21.0.255" {
		t.Errorf("dec 172.21.1.0 = %s, want 172.21.0.255", ip3)
	}
}

// itoa is a simple int-to-string for test use
func itoa(i int) string {
	return fmt.Sprintf("%d", i)
}

func TestDetectTargetOS_NilSelector(t *testing.T) {
	h := &WebhookHandler{clientset: fake.NewSimpleClientset()}
	result := h.detectTargetOS("default", nil)
	if result != "linux" {
		t.Errorf("got %s, want linux for nil selector", result)
	}
}

func TestDetectTargetOS_EmptySelector(t *testing.T) {
	h := &WebhookHandler{clientset: fake.NewSimpleClientset()}
	result := h.detectTargetOS("default", map[string]string{})
	if result != "linux" {
		t.Errorf("got %s, want linux for empty selector", result)
	}
}

func TestDetectTargetOS_PodOnWindowsNode(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "win-node",
			Labels: map[string]string{"kubernetes.io/os": "windows"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "win-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "win-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client}

	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "windows" {
		t.Errorf("got %s, want windows", result)
	}
}

func TestDetectTargetOS_PodOnLinuxNode(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "linux-node",
			Labels: map[string]string{"kubernetes.io/os": "linux"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "linux-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "linux-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client}

	result := h.detectTargetOS("default", map[string]string{"app": "linux-app"})
	if result != "linux" {
		t.Errorf("got %s, want linux", result)
	}
}

func TestDetectTargetOS_PodNotScheduled_DefaultsLinux(t *testing.T) {
	// Pod exists but not yet assigned to a node
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "pending-pod",
			Namespace: "default",
			Labels:    map[string]string{"app": "pending"},
		},
		Spec: corev1.PodSpec{},
	}
	client := fake.NewSimpleClientset(pod)
	h := &WebhookHandler{clientset: client}

	result := h.detectTargetOS("default", map[string]string{"app": "pending"})
	if result != "linux" {
		t.Errorf("got %s, want linux (pod not scheduled)", result)
	}
}

func TestDetectTargetOS_NoPods_DefaultsLinux(t *testing.T) {
	client := fake.NewSimpleClientset()
	h := &WebhookHandler{clientset: client}

	result := h.detectTargetOS("default", map[string]string{"app": "missing"})
	if result != "linux" {
		t.Errorf("got %s, want linux (no pods)", result)
	}
}

func TestDetectTargetOS_WrongNamespace_DefaultsLinux(t *testing.T) {
	node := &corev1.Node{
		ObjectMeta: metav1.ObjectMeta{
			Name:   "win-node",
			Labels: map[string]string{"kubernetes.io/os": "windows"},
		},
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: "other",
			Labels:    map[string]string{"app": "win-app"},
		},
		Spec: corev1.PodSpec{
			NodeName: "win-node",
		},
	}
	client := fake.NewSimpleClientset(node, pod)
	h := &WebhookHandler{clientset: client}

	// Service in "default", Pod in "other" — should not match
	result := h.detectTargetOS("default", map[string]string{"app": "win-app"})
	if result != "linux" {
		t.Errorf("got %s, want linux (wrong namespace)", result)
	}
}
