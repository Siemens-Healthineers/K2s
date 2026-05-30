// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

func TestShortcutRouting_NoMatch(t *testing.T) {
	sr := &shortcutRouter{
		client: &http.Client{},
	}

	body := `{"query":"something random that matches nothing"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404 for unmatched query, got %d", w.Code)
	}
}

func TestShortcutRouting_EmptyQuery(t *testing.T) {
	sr := &shortcutRouter{
		client: &http.Client{},
	}

	body := `{"query":""}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for empty query, got %d", w.Code)
	}
}

func TestShortcutRouting_MethodNotAllowed(t *testing.T) {
	sr := &shortcutRouter{
		client: &http.Client{},
	}

	req := httptest.NewRequest(http.MethodGet, "/api/shortcuts", nil)
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Errorf("expected 405 for GET, got %d", w.Code)
	}
}

func TestShortcutRouting_HealthMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAME STATUS ROLES AGE\nkubemaster Ready control-plane 10d\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"health"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for health shortcut, got %d", w.Code)
	}

	var resp shortcutResponse
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}
	if resp.Type != "shortcut" {
		t.Errorf("expected type 'shortcut', got '%s'", resp.Type)
	}
	if resp.Query != "health" {
		t.Errorf("expected query 'health', got '%s'", resp.Query)
	}
}

func TestShortcutRouting_NodesMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAME STATUS ROLES AGE VERSION\nkubemaster Ready control-plane 10d v1.30.0\nworker1 Ready <none> 5d v1.30.0\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"nodes"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !strings.Contains(resp.Status, "2/2 nodes Ready") {
		t.Errorf("expected '2/2 nodes Ready' in status, got '%s'", resp.Status)
	}
}

func TestShortcutRouting_NamespaceMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAME READY STATUS RESTARTS AGE\npod-1 1/1 Running 0 1d\npod-2 1/1 Running 0 1d\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"ns kube-system"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !strings.Contains(resp.Status, "kube-system") {
		t.Errorf("expected namespace in status, got '%s'", resp.Status)
	}
}

func TestShortcutRouting_LogsMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "INFO starting server\nERROR connection refused\nINFO retrying\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"logs my-pod default"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !strings.Contains(resp.Status, "my-pod") {
		t.Errorf("expected pod name in status, got '%s'", resp.Status)
	}
	if !strings.Contains(resp.Status, "error/fatal") {
		t.Errorf("expected error count in status, got '%s'", resp.Status)
	}
}

func TestShortcutRouting_DeployMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "Name: nginx\nReplicas: 3 desired | 3 updated | 3 total | 3 available\nConditions:\n  Available True\n  Progressing True\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"deploy nginx"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !strings.Contains(resp.Query, "deploy nginx") {
		t.Errorf("expected 'deploy nginx' in query, got '%s'", resp.Query)
	}
}

func TestShortcutRouting_DiagnoseMatch(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "Name: crash-pod\nStatus: Running\nState: Waiting\nReason: CrashLoopBackOff\nExit Code: 1\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	body := `{"query":"diagnose crash-pod"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if !strings.Contains(resp.Status, "CrashLoopBackOff") {
		t.Errorf("expected CrashLoopBackOff in status, got '%s'", resp.Status)
	}
	if !strings.Contains(resp.Details, "Cause:") {
		t.Errorf("expected 'Cause:' in details, got '%s'", resp.Details)
	}
	if !strings.Contains(resp.Details, "Action:") {
		t.Errorf("expected 'Action:' in details, got '%s'", resp.Details)
	}
}

func TestBuildOverviewSummary(t *testing.T) {
	nodes := "NAME STATUS ROLES AGE\nkubemaster Ready control-plane 10d\n"
	pods := "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 0 1d\ndefault pod-2 0/1 CrashLoopBackOff 5 1d\n"
	events := "LAST SEEN TYPE REASON MESSAGE\n5m Warning BackOff Back-off restarting\n"

	result := buildOverviewSummary(nodes, pods, events)

	if result.Type != "overview" {
		t.Errorf("expected type 'overview', got '%s'", result.Type)
	}
	if !strings.Contains(result.Status, "degraded") {
		t.Errorf("expected 'degraded' in status, got '%s'", result.Status)
	}
	if result.Nodes != "1/1 ready" {
		t.Errorf("expected '1/1 ready', got '%s'", result.Nodes)
	}
	if len(result.Issues) == 0 {
		t.Error("expected at least one issue for CrashLoopBackOff pod")
	}
}

func TestBuildOverviewSummary_CompletedPodsExcluded(t *testing.T) {
	nodes := "NAME STATUS ROLES AGE\nkubemaster Ready control-plane 10d\n"
	pods := "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 0 1d\ndefault job-abc 0/1 Completed 0 1d\ndefault job-xyz 0/1 Succeeded 0 2h\n"
	events := ""

	result := buildOverviewSummary(nodes, pods, events)

	if strings.Contains(result.Status, "degraded") {
		t.Errorf("Completed/Succeeded pods should not cause degraded status, got '%s'", result.Status)
	}
	if result.Pods != "3/3 healthy" {
		t.Errorf("expected '3/3 healthy' (completed counts as healthy), got '%s'", result.Pods)
	}
}

func TestDeduplicateEvents(t *testing.T) {
	lines := []string{
		"5m Warning BackOff pod/nginx-abc Back-off restarting failed container",
		"4m Warning BackOff pod/nginx-abc Back-off restarting failed container",
		"3m Warning BackOff pod/nginx-abc Back-off restarting failed container",
		"2m Warning Failed pod/other-pod Failed to pull image",
	}

	deduped := deduplicateEvents(lines)

	if len(deduped) != 2 {
		t.Errorf("expected 2 unique events, got %d", len(deduped))
	}
	// Most frequent first
	if deduped[0].Count != 3 {
		t.Errorf("expected first event count=3, got %d", deduped[0].Count)
	}
	if deduped[1].Count != 1 {
		t.Errorf("expected second event count=1, got %d", deduped[1].Count)
	}
	if !strings.Contains(deduped[0].Summary(), "[x3]") {
		t.Errorf("expected [x3] in summary, got '%s'", deduped[0].Summary())
	}
}

func TestFilterRecentEvents(t *testing.T) {
	lines := []string{
		"5m Warning BackOff pod/nginx recent event",
		"30m Warning Failed pod/old older event",
		"2h Warning Unhealthy pod/ancient very old event",
	}

	recent := filterRecentEvents(lines, 15*time.Minute)

	if len(recent) != 1 {
		t.Errorf("expected 1 recent event (5m), got %d", len(recent))
	}
	if len(recent) > 0 && !strings.Contains(recent[0], "5m") {
		t.Errorf("expected the 5m event, got '%s'", recent[0])
	}
}

func TestParseKubeAge(t *testing.T) {
	tests := []struct {
		input    string
		expected time.Duration
	}{
		{"5m", 5 * time.Minute},
		{"30s", 30 * time.Second},
		{"2h", 2 * time.Hour},
		{"3d", 72 * time.Hour},
		{"1h30m", 90 * time.Minute},
		{"", 0},
		{"<unknown>", 0},
	}

	for _, tc := range tests {
		got := parseKubeAge(tc.input)
		if got != tc.expected {
			t.Errorf("parseKubeAge(%q) = %v, want %v", tc.input, got, tc.expected)
		}
	}
}

func TestExtractPodFromInvestigationQuery(t *testing.T) {
	tests := []struct {
		query     string
		wantPod   string
		wantNs    string
	}{
		{"why is pod nginx-abc crashing", "nginx-abc", ""},
		{"diagnose pod my-pod default", "my-pod", "default"},
		{"crashloop web-server kube-system", "web-server", "kube-system"},
		{"diagnose failing-app", "failing-app", ""},
		{"why pod api-server not running", "api-server", ""},
	}

	for _, tc := range tests {
		pod, ns := extractPodFromInvestigationQuery(tc.query)
		if pod != tc.wantPod {
			t.Errorf("extractPodFromInvestigationQuery(%q): pod=%q, want %q", tc.query, pod, tc.wantPod)
		}
		if ns != tc.wantNs {
			t.Errorf("extractPodFromInvestigationQuery(%q): ns=%q, want %q", tc.query, ns, tc.wantNs)
		}
	}
}

func TestCorrelatePodFailure_OOMKilled(t *testing.T) {
	describe := "Name: test-pod\nStatus: Running\nLast State: Terminated\nReason: OOMKilled\nLimits:\n  memory: 256Mi\n"
	events := ""
	logs := ""

	diag := correlatePodFailure(describe, events, logs, "test-pod")

	if !strings.Contains(diag.Status, "OOMKilled") {
		t.Errorf("expected OOMKilled in status, got '%s'", diag.Status)
	}
	if !strings.Contains(diag.Cause, "memory limit") {
		t.Errorf("expected memory limit in cause, got '%s'", diag.Cause)
	}
	if !strings.Contains(diag.Action, "Increase memory") {
		t.Errorf("expected increase memory in action, got '%s'", diag.Action)
	}
}

func TestCorrelatePodFailure_ImagePullBackOff(t *testing.T) {
	describe := "Name: test-pod\nStatus: Pending\nState: Waiting\nReason: ImagePullBackOff\nImage: registry.example.com/app:v99\n"
	events := "2m Warning Failed pod/test-pod Failed to pull image registry.example.com/app:v99"
	logs := ""

	diag := correlatePodFailure(describe, events, logs, "test-pod")

	if !strings.Contains(diag.Status, "ImagePullBackOff") {
		t.Errorf("expected ImagePullBackOff in status, got '%s'", diag.Status)
	}
	if !strings.Contains(diag.Action, "image name/tag") {
		t.Errorf("expected image guidance in action, got '%s'", diag.Action)
	}
}

func TestCorrelatePodFailure_CrashLoop(t *testing.T) {
	describe := "Name: test-pod\nStatus: Running\nState: Waiting\nReason: CrashLoopBackOff\nExit Code: 1\n"
	events := ""
	logs := "ERROR: database connection failed\nFATAL: cannot start\n"

	diag := correlatePodFailure(describe, events, logs, "test-pod")

	if !strings.Contains(diag.Status, "CrashLoopBackOff") {
		t.Errorf("expected CrashLoopBackOff in status, got '%s'", diag.Status)
	}
	if len(diag.Evidence) == 0 {
		t.Error("expected evidence from logs")
	}
}

func TestIsCompletedPod(t *testing.T) {
	if !isCompletedPod("default job-abc 0/1 Completed 0 1d") {
		t.Error("expected Completed to be recognized")
	}
	if !isCompletedPod("default job-xyz 0/1 Succeeded 0 2h") {
		t.Error("expected Succeeded to be recognized")
	}
	if isCompletedPod("default pod-1 1/1 Running 0 1d") {
		t.Error("Running should not be Completed")
	}
}

// parseURL is a helper for test setup.
func parseURL(rawURL string) (*url.URL, error) {
	return url.Parse(rawURL)
}

// --- Phrase Alias Rewrite Tests ---

func TestRewriteQuery_ExactMatches(t *testing.T) {
	tests := []struct {
		input       string
		wantQuery   string
		wantAlias   string
	}{
		// Pods
		{"show all pods", "pods", "show all pods"},
		{"show me all pods", "pods", "show me all pods"},
		{"show pods", "pods", "show pods"},
		{"show me pods", "pods", "show me pods"},
		{"list all pods", "pods", "list all pods"},
		{"list pods", "pods", "list pods"},
		{"get all pods", "pods", "get all pods"},
		{"get pods", "pods", "get pods"},
		{"what pods are running", "pods", "what pods are running"},
		{"which pods are running", "pods", "which pods are running"},

		// Unhealthy/Restarting
		{"show unhealthy pods", "restarts", "show unhealthy pods"},
		{"show restarting pods", "restarts", "show restarting pods"},
		{"show crashed pods", "restarts", "show crashed pods"},
		{"show failing pods", "restarts", "show failing pods"},
		{"show failed pods", "restarts", "show failed pods"},
		{"list unhealthy pods", "restarts", "list unhealthy pods"},
		{"list restarting pods", "restarts", "list restarting pods"},
		{"pods with restarts", "restarts", "pods with restarts"},
		{"pods restarting", "restarts", "pods restarting"},
		{"which pods are unhealthy", "restarts", "which pods are unhealthy"},
		{"which pods are restarting", "restarts", "which pods are restarting"},
		{"which pods are failing", "restarts", "which pods are failing"},
		{"what is crashing", "restarts", "what is crashing"},
		{"what is restarting", "restarts", "what is restarting"},

		// Nodes
		{"show nodes", "nodes", "show nodes"},
		{"show me nodes", "nodes", "show me nodes"},
		{"show all nodes", "nodes", "show all nodes"},
		{"list nodes", "nodes", "list nodes"},
		{"get nodes", "nodes", "get nodes"},
		{"show node health", "health", "show node health"},
		{"show node status", "nodes", "show node status"},
		{"node status", "nodes", "node status"},
		{"node health", "health", "node health"},
		{"what nodes are available", "nodes", "what nodes are available"},

		// Health
		{"show health", "health", "show health"},
		{"show cluster health", "health", "show cluster health"},
		{"show me cluster health", "health", "show me cluster health"},
		{"summarize cluster health", "health", "summarize cluster health"},
		{"cluster health", "health", "cluster health"},
		{"cluster overview", "health", "cluster overview"},
		{"cluster summary", "health", "cluster summary"},
		{"how is the cluster", "health", "how is the cluster"},
		{"is the cluster healthy", "health", "is the cluster healthy"},
		{"is everything running", "health", "is everything running"},

		// Status
		{"check status", "status", "check status"},
		{"check cluster status", "status", "check cluster status"},
		{"show status", "status", "show status"},
		{"show system status", "status", "show system status"},
		{"system status", "status", "system status"},
		{"component status", "status", "component status"},
		{"platform status", "status", "platform status"},
		{"what is the status", "status", "what is the status"},

		// Events/Errors
		{"show events", "errors", "show events"},
		{"show warning events", "errors", "show warning events"},
		{"show warnings", "errors", "show warnings"},
		{"show errors", "errors", "show errors"},
		{"show me errors", "errors", "show me errors"},
		{"show recent errors", "errors", "show recent errors"},
		{"show recent events", "errors", "show recent events"},
		{"list events", "errors", "list events"},
		{"list errors", "errors", "list errors"},
		{"list warnings", "errors", "list warnings"},
		{"get events", "errors", "get events"},
		{"what warnings are there", "errors", "what warnings are there"},
		{"any errors", "errors", "any errors"},
		{"any warnings", "errors", "any warnings"},
		{"recent errors", "errors", "recent errors"},
		{"recent warnings", "errors", "recent warnings"},
		{"recent events", "errors", "recent events"},

		// Top
		{"show top", "top", "show top"},
		{"resource usage", "top", "resource usage"},
		{"show resource usage", "top", "show resource usage"},

		// Help
		{"what can you do", "help", "what can you do"},
		{"show commands", "help", "show commands"},
		{"list commands", "help", "list commands"},
		{"available commands", "help", "available commands"},

		// Deployments (no argument — show all)
		{"show deployments", "pods", "show deployments"},
		{"show all deployments", "pods", "show all deployments"},
		{"list deployments", "pods", "list deployments"},
		{"get deployments", "pods", "get deployments"},
	}

	for _, tc := range tests {
		got, alias := rewriteQuery(tc.input)
		if got != tc.wantQuery {
			t.Errorf("rewriteQuery(%q) = %q, want %q", tc.input, got, tc.wantQuery)
		}
		if alias != tc.wantAlias {
			t.Errorf("rewriteQuery(%q) alias = %q, want %q", tc.input, alias, tc.wantAlias)
		}
	}
}

func TestRewriteQuery_WithArguments(t *testing.T) {
	tests := []struct {
		input     string
		wantQuery string
		wantAlias string
	}{
		// Deployments with argument carry-forward
		{"show deployment nginx", "deploy nginx", "show deployment "},
		{"show deploy myapp", "deploy myapp", "show deploy "},
		{"check deployment frontend", "deploy frontend", "check deployment "},
		{"get deployment api-server", "deploy api-server", "get deployment "},
		{"describe deployment web", "deploy web", "describe deployment "},
		{"deployment status api", "deploy api", "deployment status "},

		// Logs with argument carry-forward
		{"show logs my-pod", "logs my-pod", "show logs "},
		{"show me logs nginx", "logs nginx", "show me logs "},
		{"get logs api-server", "logs api-server", "get logs "},
		{"tail logs my-pod", "logs my-pod", "tail logs "},
		{"tail my-pod", "logs my-pod", "tail "},

		// Diagnose with argument carry-forward
		{"investigate pod crash-pod", "diagnose crash-pod", "investigate pod "},
		{"investigate crash-pod", "diagnose crash-pod", "investigate "},
		{"troubleshoot pod web-server", "diagnose web-server", "troubleshoot pod "},
		{"troubleshoot api-pod", "diagnose api-pod", "troubleshoot "},
		{"debug pod failing-app", "diagnose failing-app", "debug pod "},
		{"debug failing-app", "diagnose failing-app", "debug "},

		// Namespace with argument carry-forward
		{"show namespace kube-system", "ns kube-system", "show namespace "},
		{"show ns monitoring", "ns monitoring", "show ns "},
		{"pods in default", "ns default", "pods in "},
		{"list pods in kube-system", "ns kube-system", "list pods in "},
		{"show pods in monitoring", "ns monitoring", "show pods in "},

		// Why is -> why is pod (carry-forward)
		{"why is nginx crashing", "why is pod nginx crashing", "why is "},
	}

	for _, tc := range tests {
		got, alias := rewriteQuery(tc.input)
		if got != tc.wantQuery {
			t.Errorf("rewriteQuery(%q) = %q, want %q", tc.input, got, tc.wantQuery)
		}
		if alias != tc.wantAlias {
			t.Errorf("rewriteQuery(%q) alias = %q, want %q", tc.input, alias, tc.wantAlias)
		}
	}
}

func TestRewriteQuery_NoMatch(t *testing.T) {
	queries := []string{
		"something random",
		"how do I scale a deployment",
		"explain kubernetes networking",
		"what is a pod",
		"create namespace test",
		"delete pod nginx",
		"apply manifest",
	}

	for _, q := range queries {
		got, alias := rewriteQuery(q)
		if got != q {
			t.Errorf("rewriteQuery(%q) should return unchanged, got %q", q, got)
		}
		if alias != "" {
			t.Errorf("rewriteQuery(%q) should have empty alias, got %q", q, alias)
		}
	}
}

func TestRewriteQuery_CaseInsensitive(t *testing.T) {
	// rewriteQuery expects lowercased input (caller responsibility),
	// verify it works with pre-lowercased input
	got, alias := rewriteQuery("show all pods")
	if got != "pods" || alias == "" {
		t.Errorf("expected rewrite to 'pods', got %q (alias=%q)", got, alias)
	}
}

func TestPhraseAliasEndToEnd_PodsShortcut(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 0 1d\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	// "show all pods" should rewrite to "pods" and match the pods shortcut
	body := `{"query":"show all pods"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for 'show all pods', got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Type != "shortcut" {
		t.Errorf("expected type 'shortcut', got '%s'", resp.Type)
	}
}

func TestPhraseAliasEndToEnd_HealthShortcut(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAME STATUS ROLES AGE\nkubemaster Ready control-plane 10d\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	// "summarize cluster health" should rewrite to "health"
	body := `{"query":"summarize cluster health"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for 'summarize cluster health', got %d", w.Code)
	}

	var resp shortcutResponse
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp.Type != "shortcut" {
		t.Errorf("expected type 'shortcut', got '%s'", resp.Type)
	}
}

func TestPhraseAliasEndToEnd_NoMatchFallsThrough(t *testing.T) {
	sr := &shortcutRouter{
		client: &http.Client{},
	}

	// A non-matching phrase should still return 404
	body := `{"query":"explain kubernetes networking"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("expected 404 for non-matching query, got %d", w.Code)
	}
}

func TestPhraseAliasEndToEnd_RestartsShortcut(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": "NAMESPACE NAME READY STATUS RESTARTS AGE\ndefault pod-1 1/1 Running 3 1d\n"},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	// "show unhealthy pods" should rewrite to "restarts"
	body := `{"query":"show unhealthy pods"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for 'show unhealthy pods', got %d", w.Code)
	}
}

func TestPhraseAliasEndToEnd_ErrorsShortcut(t *testing.T) {
	mockMCP := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		result := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"content": []map[string]interface{}{
					{"type": "text", "text": ""},
				},
			},
		}
		json.NewEncoder(w).Encode(result)
	}))
	defer mockMCP.Close()

	mcpURL, _ := parseURL(mockMCP.URL)
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	// "show warning events" should rewrite to "errors"
	body := `{"query":"show warning events"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for 'show warning events', got %d", w.Code)
	}
}

func TestPhraseAliasEndToEnd_StatusShortcut(t *testing.T) {
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
	sr := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	// "check cluster status" should rewrite to "status"
	body := `{"query":"check cluster status"}`
	req := httptest.NewRequest(http.MethodPost, "/api/shortcuts", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	sr.handleShortcuts(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200 for 'check cluster status', got %d", w.Code)
	}
}

func TestPhraseAliasCoverage_AllExamplesFromSpec(t *testing.T) {
	// These are the exact examples from the M3 task specification
	specExamples := []struct {
		phrase   string
		wantTarget string // expected canonical shortcut prefix
	}{
		{"show all pods", "pods"},
		{"list pods", "pods"},
		{"get pods", "pods"},
		{"show node health", "health"},
		{"summarize cluster health", "health"},
		{"show warning events", "errors"},
		{"show restarting pods", "restarts"},
		{"show unhealthy pods", "restarts"},
		{"check cluster status", "status"},
	}

	for _, tc := range specExamples {
		got, alias := rewriteQuery(tc.phrase)
		if !strings.HasPrefix(got, tc.wantTarget) {
			t.Errorf("M3 spec example %q: rewriteQuery returned %q, expected prefix %q", tc.phrase, got, tc.wantTarget)
		}
		if alias == "" {
			t.Errorf("M3 spec example %q: should match an alias but didn't", tc.phrase)
		}
	}
}
