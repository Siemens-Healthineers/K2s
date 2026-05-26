// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestCallToolWithTimeout_Success(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "ok"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()}

	out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "node"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out != "ok" {
		t.Errorf("expected 'ok', got '%s'", out)
	}
}

func TestCallToolWithTimeout_Timeout(t *testing.T) {
	// Server that hangs forever
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(15 * time.Second) // longer than toolCallTimeout
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: &http.Client{Timeout: 12 * time.Second}}

	_, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "node"})
	if err == nil {
		t.Fatal("expected timeout error")
	}
	if !strings.Contains(err.Error(), "timeout") {
		t.Errorf("expected 'timeout' in error, got '%s'", err.Error())
	}
}

func TestStructuredError_Format(t *testing.T) {
	elapsed := 2 * time.Second
	se := newStructuredError("k2s-tools", "tool call timeout (10s)", "Query could not complete", elapsed)

	if se.Type != "error" {
		t.Errorf("expected type 'error', got '%s'", se.Type)
	}
	if se.Component != "k2s-tools" {
		t.Errorf("expected component 'k2s-tools', got '%s'", se.Component)
	}
	if !strings.Contains(se.FailureReason, "timeout") {
		t.Errorf("expected timeout in failure_reason, got '%s'", se.FailureReason)
	}
	if se.Reason != ErrToolTimeout {
		t.Errorf("expected reason '%s', got '%s'", ErrToolTimeout, se.Reason)
	}
	if len(se.AvailableWorkflows) == 0 {
		t.Error("expected available_workflows to be populated")
	}
	if se.Elapsed != "2.0s" {
		t.Errorf("expected '2.0s', got '%s'", se.Elapsed)
	}
	if se.Confidence != "low" {
		t.Errorf("expected confidence 'low', got '%s'", se.Confidence)
	}
	// RequestID empty by default, populated by handler
	if se.RequestID != "" {
		t.Errorf("expected empty requestId by default, got '%s'", se.RequestID)
	}
}

func TestClassifyErrorCategory(t *testing.T) {
	tests := []struct {
		component string
		reason    string
		expected  string
	}{
		{"ollama", "ollama connection refused", ErrOllamaUnreachable},
		{"k2s-tools", "tool call timeout (10s)", ErrToolTimeout},
		{"kubernetes-api", "RBAC denied", ErrRBACDenied},
		{"kubernetes-api", "forbidden", ErrRBACDenied},
		{"kubernetes-api", "resource not found", ErrResourceNotFound},
		{"kubernetes-api", "connection refused", ErrKubernetesUnreachable},
		{"mcp-preprocessor", "connection refused", ErrPreprocessingFailure},
		{"unknown", "something else", ErrToolTimeout},
	}
	for _, tt := range tests {
		got := classifyErrorCategory(tt.component, tt.reason)
		if got != tt.expected {
			t.Errorf("classifyErrorCategory(%q, %q) = %q, want %q", tt.component, tt.reason, got, tt.expected)
		}
	}
}

func TestComputeConfidence(t *testing.T) {
	if computeConfidence(3, 0) != "high" {
		t.Error("0 failures should be high")
	}
	if computeConfidence(3, 1) != "partial" {
		t.Error("1/3 failures should be partial")
	}
	if computeConfidence(3, 2) != "partial" {
		t.Error("2/3 failures should be partial")
	}
	if computeConfidence(3, 3) != "low" {
		t.Error("3/3 failures should be low")
	}
}

func TestHandleShortcutError_Timeout(t *testing.T) {
	w := httptest.NewRecorder()
	err := fmt.Errorf("tool call timeout after 10s: k8s_get_resources")
	start := time.Now().Add(-3 * time.Second)

	handleShortcutError(w, err, "health", start)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("expected 500, got %d", w.Code)
	}

	var se structuredError
	json.Unmarshal(w.Body.Bytes(), &se)
	if se.Type != "error" {
		t.Errorf("expected type 'error', got '%s'", se.Type)
	}
	if se.Component != "k2s-tools" {
		t.Errorf("expected component 'k2s-tools', got '%s'", se.Component)
	}
	if !strings.Contains(se.FailureReason, "timeout") {
		t.Errorf("expected 'timeout' in failure_reason, got '%s'", se.FailureReason)
	}
}

func TestHandleShortcutError_ConnectionRefused(t *testing.T) {
	w := httptest.NewRecorder()
	err := fmt.Errorf("upstream call: dial tcp: connection refused")
	start := time.Now()

	handleShortcutError(w, err, "nodes", start)

	var se structuredError
	json.Unmarshal(w.Body.Bytes(), &se)
	if se.Component != "mcp-preprocessor" {
		t.Errorf("expected component 'mcp-preprocessor', got '%s'", se.Component)
	}
}

func TestHandleShortcutError_RBAC(t *testing.T) {
	w := httptest.NewRecorder()
	err := fmt.Errorf("tool error: forbidden: user system:serviceaccount cannot list pods")
	start := time.Now()

	handleShortcutError(w, err, "pods", start)

	var se structuredError
	json.Unmarshal(w.Body.Bytes(), &se)
	if se.Component != "kubernetes-api" {
		t.Errorf("expected component 'kubernetes-api', got '%s'", se.Component)
	}
	if !strings.Contains(se.FailureReason, "RBAC") {
		t.Errorf("expected 'RBAC' in failure_reason, got '%s'", se.FailureReason)
	}
}

func TestStatusShortcut(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "default\nkube-system\nkagent\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	// Initialize monitor for test
	globalOllamaMonitor = &ollamaMonitor{}
	globalOllamaMonitor.reachable.Store(1)
	globalOllamaMonitor.lastLatency.Store(50000) // 50ms in microseconds
	globalOllamaMonitor.lastError.Store("")

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()}

	body := `{"query":"status"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Query != "status" {
		t.Errorf("expected query 'status', got '%s'", resp.Query)
	}
	if !strings.Contains(resp.Status, "operational") {
		t.Errorf("expected 'operational' in status, got '%s'", resp.Status)
	}
}

func TestReadyzEndpoint(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "default\nkube-system\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	// Initialize monitor
	globalOllamaMonitor = &ollamaMonitor{}
	globalOllamaMonitor.reachable.Store(1)
	globalOllamaMonitor.lastLatency.Store(30000)
	globalOllamaMonitor.lastError.Store("")

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()}

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()

	sr.handleReadyz(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp readyzResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Status != "ready" {
		t.Errorf("expected status 'ready', got '%s'", resp.Status)
	}
	if resp.Components["mcp-preprocessor"].Status != "healthy" {
		t.Errorf("expected mcp-preprocessor healthy, got '%s'", resp.Components["mcp-preprocessor"].Status)
	}
	if resp.Components["ollama"].Status != "healthy" {
		t.Errorf("expected ollama healthy, got '%s'", resp.Components["ollama"].Status)
	}
}

func TestReadyzEndpoint_Degraded(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "default\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	// Ollama unreachable
	globalOllamaMonitor = &ollamaMonitor{}
	globalOllamaMonitor.reachable.Store(0)
	globalOllamaMonitor.lastLatency.Store(0)
	globalOllamaMonitor.lastError.Store("connection refused")

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()}

	req := httptest.NewRequest(http.MethodGet, "/readyz", nil)
	w := httptest.NewRecorder()

	sr.handleReadyz(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 (degraded but still serves shortcuts), got %d", w.Code)
	}

	var resp readyzResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Status != "degraded" {
		t.Errorf("expected 'degraded', got '%s'", resp.Status)
	}
	if resp.Components["ollama"].Status != "unavailable" {
		t.Errorf("expected ollama unavailable, got '%s'", resp.Components["ollama"].Status)
	}
}

func TestBuildOverviewWithPartialResults_NodesFailed(t *testing.T) {
	pods := "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 0 1d\n"
	events := ""

	result := buildOverviewWithPartialResults("", pods, events, true, false, false)

	if result.Nodes != "unavailable" {
		t.Errorf("expected nodes 'unavailable', got '%s'", result.Nodes)
	}
	if !strings.Contains(result.Status, "partial") {
		t.Errorf("expected 'partial' in status, got '%s'", result.Status)
	}
	if result.Confidence != "partial" {
		t.Errorf("expected confidence 'partial', got '%s'", result.Confidence)
	}
}

func TestBuildOverviewWithPartialResults_AllFailed(t *testing.T) {
	result := buildOverviewWithPartialResults("", "", "", true, true, true)

	if result.Confidence != "low" {
		t.Errorf("expected confidence 'low', got '%s'", result.Confidence)
	}
}

func TestBuildOverviewWithPartialResults_AllSucceed(t *testing.T) {
	nodes := "NAME STATUS\nnode1 Ready\n"
	pods := "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 0 1d\n"
	events := ""

	result := buildOverviewWithPartialResults(nodes, pods, events, false, false, false)

	if result.Confidence != "high" {
		t.Errorf("expected confidence 'high', got '%s'", result.Confidence)
	}
}

func TestStatusShortcut_OllamaDegraded(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			w.WriteHeader(http.StatusOK)
			w.Write([]byte("ok"))
			return
		}
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "node1 Ready\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	// Ollama unreachable
	globalOllamaMonitor = &ollamaMonitor{}
	globalOllamaMonitor.reachable.Store(0)
	globalOllamaMonitor.lastLatency.Store(0)
	globalOllamaMonitor.lastError.Store("connection refused")

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()}

	resp, err := handleStatusShortcut(sr, "status")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(resp.Status, "Ollama unreachable") {
		t.Errorf("expected 'Ollama unreachable' in status, got '%s'", resp.Status)
	}
	if !strings.Contains(resp.Status, "Deterministic workflows still operational") {
		t.Errorf("expected deterministic workflows note, got '%s'", resp.Status)
	}
	if !strings.Contains(resp.Details, "Available workflows during degradation") {
		t.Errorf("expected available workflows section in details, got '%s'", resp.Details)
	}
}

func TestOllamaMonitor_StatusString(t *testing.T) {
	m := &ollamaMonitor{}
	m.lastError.Store("")

	m.reachable.Store(1)
	if m.statusString() != "reachable" {
		t.Errorf("expected 'reachable', got '%s'", m.statusString())
	}

	m.reachable.Store(0)
	m.lastError.Store("connection refused")
	if !strings.Contains(m.statusString(), "connection refused") {
		t.Errorf("expected 'connection refused' in status, got '%s'", m.statusString())
	}
}

func TestAvailableShortcuts(t *testing.T) {
	sc := availableShortcuts()
	if len(sc) == 0 {
		t.Error("expected non-empty available shortcuts")
	}
	// Must include "status"
	found := false
	for _, s := range sc {
		if s == "status" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected 'status' in available shortcuts")
	}
}

