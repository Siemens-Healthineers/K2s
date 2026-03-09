// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ve "github.com/siemens-healthineers/k2s/internal/version"
	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

const (
	cliName = "clusterip-webhook"

	nodeOSKey = "kubernetes.io/os"

	defaultLinuxSubnet   = "172.21.0.0/24"
	defaultWindowsSubnet = "172.21.1.0/24"
	defaultReservedIPs   = 50 // IPs 0-49 are reserved by K2s

	certFile = "/certs/tls.crt"
	keyFile  = "/certs/tls.key"
)

var (
	scheme = runtime.NewScheme()
	codecs = serializer.NewCodecFactory(scheme)
)

func main() {
	var addr string
	var linuxSubnet string
	var windowsSubnet string
	var reservedIPs int
	var tlsCert string
	var tlsKey string

	versionFlag := cli.NewVersionFlag(cliName)
	flag.StringVar(&addr, "addr", ":8443", "address to listen on")
	flag.StringVar(&linuxSubnet, "linux-subnet", defaultLinuxSubnet, "CIDR for Linux service ClusterIPs")
	flag.StringVar(&windowsSubnet, "windows-subnet", defaultWindowsSubnet, "CIDR for Windows service ClusterIPs")
	flag.IntVar(&reservedIPs, "reserved-ips", defaultReservedIPs, "number of IPs reserved at the start of each subnet")
	flag.StringVar(&tlsCert, "tls-cert", certFile, "path to TLS certificate")
	flag.StringVar(&tlsKey, "tls-key", keyFile, "path to TLS private key")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))
	slog.Info("Starting", "name", cliName, "addr", addr,
		"linuxSubnet", linuxSubnet, "windowsSubnet", windowsSubnet, "reservedIPs", reservedIPs)

	config, err := rest.InClusterConfig()
	if err != nil {
		slog.Error("Failed to create in-cluster config", "error", err)
		os.Exit(1)
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		slog.Error("Failed to create Kubernetes clientset", "error", err)
		os.Exit(1)
	}

	allocator, err := NewIPAllocator(linuxSubnet, windowsSubnet, reservedIPs)
	if err != nil {
		slog.Error("Failed to create IP allocator", "error", err)
		os.Exit(1)
	}

	handler := &WebhookHandler{
		clientset: clientset,
		allocator: allocator,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", handler.handleMutate)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	tlsCertPair, err := tls.LoadX509KeyPair(tlsCert, tlsKey)
	if err != nil {
		slog.Error("Failed to load TLS certificate", "error", err, "cert", tlsCert, "key", tlsKey)
		os.Exit(1)
	}

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
		TLSConfig: &tls.Config{
			Certificates: []tls.Certificate{tlsCertPair},
			MinVersion:   tls.VersionTLS12,
		},
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		slog.Info("Listening", "addr", addr)
		if err := server.ListenAndServeTLS("", ""); err != nil && err != http.ErrServerClosed {
			slog.Error("Server failed", "error", err)
			os.Exit(1)
		}
	}()

	<-stop
	slog.Info("Shutting down")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		slog.Error("Shutdown error", "error", err)
	}
}

// WebhookHandler handles admission review requests for Service resources.
type WebhookHandler struct {
	clientset *kubernetes.Clientset
	allocator *IPAllocator
}

func (h *WebhookHandler) handleMutate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("Failed to read request body", "error", err)
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}

	admissionReview := admissionv1.AdmissionReview{}
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		slog.Error("Failed to unmarshal AdmissionReview", "error", err)
		http.Error(w, "failed to unmarshal", http.StatusBadRequest)
		return
	}

	request := admissionReview.Request
	if request == nil {
		slog.Error("AdmissionReview request is nil")
		http.Error(w, "empty request", http.StatusBadRequest)
		return
	}

	slog.Info("Received admission request",
		"uid", request.UID,
		"kind", request.Kind.Kind,
		"namespace", request.Namespace,
		"name", request.Name,
		"operation", request.Operation)

	response := h.mutateService(request)

	admissionReview.Response = response
	admissionReview.Response.UID = request.UID

	respBytes, err := json.Marshal(admissionReview)
	if err != nil {
		slog.Error("Failed to marshal response", "error", err)
		http.Error(w, "failed to marshal response", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.Write(respBytes)
}

func (h *WebhookHandler) mutateService(request *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
	// Only process Service CREATE requests
	if request.Kind.Kind != "Service" || request.Operation != admissionv1.Create {
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	var service corev1.Service
	if err := json.Unmarshal(request.Object.Raw, &service); err != nil {
		slog.Error("Failed to unmarshal Service", "error", err)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to unmarshal service: %v", err),
			},
		}
	}

	// Skip if clusterIP is already set explicitly
	if service.Spec.ClusterIP != "" && service.Spec.ClusterIP != "None" {
		slog.Info("Service already has clusterIP, skipping",
			"name", service.Name, "namespace", service.Namespace, "clusterIP", service.Spec.ClusterIP)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Skip headless services
	if service.Spec.ClusterIP == "None" {
		slog.Info("Service is headless, skipping", "name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Skip non-ClusterIP service types (ExternalName has no clusterIP)
	if service.Spec.Type == corev1.ServiceTypeExternalName {
		slog.Info("Service is ExternalName, skipping", "name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{Allowed: true}
	}

	// Determine target OS by inspecting workloads that match the Service selector
	targetOS := h.detectTargetOS(service.Namespace, service.Spec.Selector)
	slog.Info("Detected target OS", "os", targetOS, "name", service.Name, "namespace", service.Namespace)

	// Get all existing service IPs to avoid conflicts
	usedIPs, err := h.getUsedClusterIPs()
	if err != nil {
		slog.Error("Failed to list existing services", "error", err)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to list existing services: %v", err),
			},
		}
	}

	// Allocate next free IP
	ip, err := h.allocator.AllocateIP(targetOS, usedIPs)
	if err != nil {
		slog.Error("Failed to allocate IP", "error", err, "os", targetOS,
			"name", service.Name, "namespace", service.Namespace)
		return &admissionv1.AdmissionResponse{
			Allowed: false,
			Result: &metav1.Status{
				Message: fmt.Sprintf("failed to allocate ClusterIP for %s service: %v", targetOS, err),
			},
		}
	}

	slog.Info("Allocating ClusterIP",
		"name", service.Name, "namespace", service.Namespace,
		"os", targetOS, "clusterIP", ip)

	// Create JSON patch to set spec.clusterIP
	patch := fmt.Sprintf(`[{"op": "add", "path": "/spec/clusterIP", "value": "%s"}]`, ip)
	patchType := admissionv1.PatchTypeJSONPatch

	return &admissionv1.AdmissionResponse{
		Allowed:   true,
		PatchType: &patchType,
		Patch:     []byte(patch),
	}
}

func (h *WebhookHandler) getUsedClusterIPs() (map[string]bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	services, err := h.clientset.CoreV1().Services("").List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, fmt.Errorf("listing services: %w", err)
	}

	used := make(map[string]bool, len(services.Items))
	for _, svc := range services.Items {
		if svc.Spec.ClusterIP != "" && svc.Spec.ClusterIP != "None" {
			used[svc.Spec.ClusterIP] = true
		}
	}

	return used, nil
}

// detectTargetOS discovers the OS for a Service by inspecting workloads and pods
// that match the Service's selector. It checks in order:
//  1. Deployments, StatefulSets, DaemonSets with a kubernetes.io/os nodeSelector
//  2. Running Pods → their Node's kubernetes.io/os label
//  3. Defaults to "linux"
func (h *WebhookHandler) detectTargetOS(namespace string, selector map[string]string) string {
	if len(selector) == 0 {
		slog.Info("Service has no selector, defaulting to linux", "namespace", namespace)
		return "linux"
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Strategy 1: Check workload nodeSelectors
	if os := h.detectOSFromWorkloads(ctx, namespace, selector); os != "" {
		return os
	}

	// Strategy 2: Check running pods → node labels
	if os := h.detectOSFromPods(ctx, namespace, selector); os != "" {
		return os
	}

	slog.Info("No OS detected from workloads or pods, defaulting to linux", "namespace", namespace)
	return "linux"
}

// detectOSFromWorkloads checks Deployments, StatefulSets, and DaemonSets in the
// namespace for a pod template whose labels are a superset of the Service selector
// and whose nodeSelector contains kubernetes.io/os.
func (h *WebhookHandler) detectOSFromWorkloads(ctx context.Context, namespace string, selector map[string]string) string {
	selectorSet := labels.Set(selector)

	// Check Deployments
	deployments, err := h.clientset.AppsV1().Deployments(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list Deployments", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(deployments.Items, selectorSet); os != "" {
			return os
		}
	}

	// Check StatefulSets
	statefulSets, err := h.clientset.AppsV1().StatefulSets(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list StatefulSets", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(statefulSets.Items, selectorSet); os != "" {
			return os
		}
	}

	// Check DaemonSets
	daemonSets, err := h.clientset.AppsV1().DaemonSets(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		slog.Warn("Failed to list DaemonSets", "error", err, "namespace", namespace)
	} else {
		if os := osFromPodSpecs(daemonSets.Items, selectorSet); os != "" {
			return os
		}
	}

	return ""
}

// workload is satisfied by Deployment, StatefulSet, and DaemonSet.
type workload interface {
	appsv1.Deployment | appsv1.StatefulSet | appsv1.DaemonSet
}

func osFromPodSpecs[T workload](items []T, selectorSet labels.Set) string {
	for i := range items {
		var podLabels map[string]string
		var nodeSelector map[string]string
		switch w := any(&items[i]).(type) {
		case *appsv1.Deployment:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		case *appsv1.StatefulSet:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		case *appsv1.DaemonSet:
			podLabels = w.Spec.Template.Labels
			nodeSelector = w.Spec.Template.Spec.NodeSelector
		}
		// Service selector must be a subset of the pod template labels
		if !selectorSet.AsSelector().Matches(labels.Set(podLabels)) {
			continue
		}
		if os, ok := nodeSelector[nodeOSKey]; ok {
			return strings.ToLower(os)
		}
	}
	return ""
}

// detectOSFromPods finds pods matching the selector, then checks their node's
// kubernetes.io/os label.
func (h *WebhookHandler) detectOSFromPods(ctx context.Context, namespace string, selector map[string]string) string {
	labelParts := make([]string, 0, len(selector))
	for k, v := range selector {
		labelParts = append(labelParts, k+"="+v)
	}
	labelSelector := strings.Join(labelParts, ",")

	pods, err := h.clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{LabelSelector: labelSelector})
	if err != nil {
		slog.Warn("Failed to list Pods", "error", err, "namespace", namespace)
		return ""
	}

	for _, pod := range pods.Items {
		if pod.Spec.NodeName == "" {
			continue
		}
		node, err := h.clientset.CoreV1().Nodes().Get(ctx, pod.Spec.NodeName, metav1.GetOptions{})
		if err != nil {
			slog.Warn("Failed to get Node", "error", err, "node", pod.Spec.NodeName)
			continue
		}
		if os, ok := node.Labels[nodeOSKey]; ok {
			return strings.ToLower(os)
		}
	}

	return ""
}

// IPAllocator manages IP allocation from Linux and Windows subnets.
type IPAllocator struct {
	linuxStart   net.IP
	linuxEnd     net.IP
	windowsStart net.IP
	windowsEnd   net.IP
}

// NewIPAllocator creates an allocator for the given CIDR ranges,
// skipping the first reservedIPs addresses in each subnet.
func NewIPAllocator(linuxCIDR, windowsCIDR string, reservedIPs int) (*IPAllocator, error) {
	linuxStart, linuxEnd, err := subnetRange(linuxCIDR, reservedIPs)
	if err != nil {
		return nil, fmt.Errorf("invalid linux CIDR %q: %w", linuxCIDR, err)
	}

	windowsStart, windowsEnd, err := subnetRange(windowsCIDR, reservedIPs)
	if err != nil {
		return nil, fmt.Errorf("invalid windows CIDR %q: %w", windowsCIDR, err)
	}

	return &IPAllocator{
		linuxStart:   linuxStart,
		linuxEnd:     linuxEnd,
		windowsStart: windowsStart,
		windowsEnd:   windowsEnd,
	}, nil
}

// AllocateIP returns the next available IP in the appropriate subnet.
func (a *IPAllocator) AllocateIP(osType string, usedIPs map[string]bool) (string, error) {
	var start, end net.IP
	if osType == "windows" {
		start = a.windowsStart
		end = a.windowsEnd
	} else {
		start = a.linuxStart
		end = a.linuxEnd
	}

	for ip := dupIP(start); !ip.Equal(end); incIP(ip) {
		candidate := ip.String()
		if !usedIPs[candidate] {
			return candidate, nil
		}
	}

	// Check the end IP too
	if !usedIPs[end.String()] {
		return end.String(), nil
	}

	return "", fmt.Errorf("no free IPs in %s subnet (range %s - %s)", osType, start, end)
}

// subnetRange returns the allocatable IP range [start, end] for a CIDR,
// skipping the network address and the first reservedIPs host addresses,
// and excluding the broadcast address.
func subnetRange(cidr string, reservedIPs int) (net.IP, net.IP, error) {
	_, ipNet, err := net.ParseCIDR(cidr)
	if err != nil {
		return nil, nil, err
	}

	// Start = network + reservedIPs (skip .0 through .reservedIPs-1)
	start := dupIP(ipNet.IP)
	for i := 0; i < reservedIPs; i++ {
		incIP(start)
	}

	// End = broadcast - 1
	end := broadcastAddr(ipNet)
	decIP(end)

	if start.Equal(end) || bytesGreater(start, end) {
		return nil, nil, fmt.Errorf("subnet %s too small for %d reserved IPs", cidr, reservedIPs)
	}

	return start, end, nil
}

func broadcastAddr(n *net.IPNet) net.IP {
	ip := dupIP(n.IP)
	for i := range ip {
		ip[i] |= ^n.Mask[i]
	}
	return ip
}

func dupIP(ip net.IP) net.IP {
	dup := make(net.IP, len(ip))
	copy(dup, ip)
	return dup
}

func incIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}

func decIP(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]--
		if ip[j] < 255 {
			break
		}
	}
}

func bytesGreater(a, b net.IP) bool {
	for i := range a {
		if a[i] > b[i] {
			return true
		}
		if a[i] < b[i] {
			return false
		}
	}
	return false
}
