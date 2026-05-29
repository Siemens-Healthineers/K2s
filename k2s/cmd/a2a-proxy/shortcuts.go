// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Query shortcuts — deterministic fast-path responses that bypass LLM inference.
// Each shortcut maps to a fixed MCP tool-call sequence executed directly against
// the mcp-preprocessor, formatted into a concise operational summary.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"sync"
	"time"
)

// shortcutRouter handles /api/shortcuts requests.
type shortcutRouter struct {
	mcpUpstream *url.URL // mcp-preprocessor URL
	client      *http.Client
}

// shortcutResponse is the structured response returned by shortcuts.
type shortcutResponse struct {
	Type      string   `json:"type"`      // "shortcut"
	Query     string   `json:"query"`     // original query matched
	Status    string   `json:"status"`    // one-line status
	Details   string   `json:"details"`   // detailed output
	Elapsed   string   `json:"elapsed"`   // response time
	Followups []string `json:"followups"` // suggested follow-up queries (max 3)
}

// shortcutDefinition defines a deterministic shortcut.
type shortcutDefinition struct {
	// Pattern to match (lowercased query must start with this)
	Pattern string
	// Handler that executes the shortcut and returns formatted output
	Handler func(sr *shortcutRouter, query string) (*shortcutResponse, error)
}

// shortcuts is the ordered list of shortcut definitions.
// Order matters: more specific patterns must come before general ones.
var shortcuts = []shortcutDefinition{
	// Help — must be first
	{Pattern: "help", Handler: handleHelpShortcut},
	// Investigation plans (multi-step deterministic workflows)
	{Pattern: "why is pod ", Handler: handlePodCrashInvestigation},
	{Pattern: "why pod ", Handler: handlePodCrashInvestigation},
	{Pattern: "diagnose pod ", Handler: handlePodCrashInvestigation},
	{Pattern: "diagnose ", Handler: handlePodCrashInvestigation},
	{Pattern: "crashloop ", Handler: handlePodCrashInvestigation},
	// Standard shortcuts
	{Pattern: "status", Handler: handleStatusShortcut},
	{Pattern: "health", Handler: handleHealthShortcut},
	{Pattern: "errors", Handler: handleErrorsShortcut},
	{Pattern: "top", Handler: handleTopShortcut},
	{Pattern: "nodes", Handler: handleNodesShortcut},
	{Pattern: "restarts", Handler: handleRestartsShortcut},
	{Pattern: "logs ", Handler: handleLogsShortcut},
	{Pattern: "deploy ", Handler: handleDeployShortcut},
	{Pattern: "ns ", Handler: handleNamespaceShortcut},
	{Pattern: "pods", Handler: handlePodsShortcut},
	{Pattern: "pod ", Handler: handlePodShortcut},
}

// handleHelpShortcut returns all available shortcuts grouped by category.
func handleHelpShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	details := `CLUSTER OVERVIEW
  health          Cluster health summary (nodes, pods, warnings)
  status          Component status (ollama, mcp, k2s-tools, kubernetes-api)
  nodes           Node list with status and versions
  pods            All pods across namespaces with counts
  top             Pod resource overview sorted by status
  errors          Warning events from last 15 minutes (deduplicated)
  restarts        Pods with restart counts

RESOURCE INSPECTION
  ns <namespace>          Pods in a specific namespace
  pod <name> [ns]         Describe a pod
  logs <pod> [ns] [ctr]   Tail logs (50 lines)
  deploy <name> [ns]      Deployment rollout status and conditions

DIAGNOSTICS
  diagnose <pod> [ns]     Multi-step crash investigation (describe+events+logs)
  why is pod <pod> crashing    Same as diagnose
  crashloop <pod>              Same as diagnose

SYSTEM
  status          Component health probes
  help            This help text

All shortcuts execute deterministically without LLM. Sub-second response.
For free-form queries, use the kagent-ui chat (requires Ollama).`

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "help",
		Status:    "14 shortcuts available across 4 categories",
		Details:   details,
		Followups: []string{"health", "status", "nodes"},
	}, nil
}

func (sr *shortcutRouter) handleShortcuts(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	// Parse query from request body
	var req struct {
		Query string `json:"query"`
	}
	if err := json.Unmarshal(body, &req); err != nil {
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	query := strings.TrimSpace(strings.ToLower(req.Query))
	if query == "" {
		http.Error(w, `{"error":"empty query"}`, http.StatusBadRequest)
		return
	}

	// Match against shortcuts
	for _, sc := range shortcuts {
		if strings.HasPrefix(query, sc.Pattern) || query == strings.TrimSpace(sc.Pattern) {
			resp, err := sc.Handler(sr, req.Query)
			if err != nil {
				slog.Error("[Shortcuts] Handler failed", "pattern", sc.Pattern, "error", err)
				handleShortcutError(w, err, req.Query, start)
				return
			}
			resp.Elapsed = fmt.Sprintf("%.1fs", time.Since(start).Seconds())
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(resp)
			recordShortcut(sc.Pattern, time.Since(start))
			return
		}
	}

	// No shortcut matched — return 404 so caller falls through to LLM path
	w.WriteHeader(http.StatusNotFound)
	w.Write([]byte(`{"error":"no matching shortcut"}`))
}

// handleOverview handles GET /api/overview — cluster summary without LLM.
func (sr *shortcutRouter) handleOverview(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// Execute 3 tool calls in parallel: nodes, failing pods, warning events
	type result struct {
		key  string
		data string
		err  error
	}

	results := make(chan result, 3)
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{
			"resource_type": "node",
		})
		results <- result{key: "nodes", data: out, err: err}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{
			"resource_type":  "pod",
			"all_namespaces": "true",
		})
		results <- result{key: "pods", data: out, err: err}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_events", map[string]interface{}{
			"namespace": "all",
		})
		results <- result{key: "events", data: out, err: err}
	}()

	go func() {
		wg.Wait()
		close(results)
	}()

	data := make(map[string]string)
	failed := make(map[string]bool)
	for r := range results {
		if r.err != nil {
			slog.Warn("[Overview] Tool call failed", "tool", r.key, "error", r.err)
			data[r.key] = ""
			failed[r.key] = true
		} else {
			data[r.key] = r.data
		}
	}

	// Build overview with partial-result annotations
	overview := buildOverviewWithPartialResults(
		data["nodes"], data["pods"], data["events"],
		failed["nodes"], failed["pods"], failed["events"],
	)
	overview.Elapsed = fmt.Sprintf("%.1fs", time.Since(start).Seconds())

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(overview)
	recordShortcut("overview", time.Since(start))
}

// --- Shortcut Handlers ---

func handleHealthShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	type result struct {
		key  string
		data string
		err  error
	}
	results := make(chan result, 3)
	var wg sync.WaitGroup

	wg.Add(3)
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "node"})
		results <- result{"nodes", out, err}
	}()
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "pod", "all_namespaces": "true"})
		results <- result{"pods", out, err}
	}()
	go func() {
		defer wg.Done()
		out, err := sr.callToolWithTimeout("k8s_get_events", map[string]interface{}{"namespace": "all"})
		results <- result{"events", out, err}
	}()
	go func() { wg.Wait(); close(results) }()

	data := make(map[string]string)
	failed := make(map[string]bool)
	for r := range results {
		if r.err == nil {
			data[r.key] = r.data
		} else {
			failed[r.key] = true
		}
	}

	summary := buildOverviewWithPartialResults(data["nodes"], data["pods"], data["events"],
		failed["nodes"], failed["pods"], failed["events"])
	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "health",
		Status:    summary.Status,
		Details:   summary.Details,
		Followups: []string{"errors", "status", "nodes"},
	}, nil
}

func handleErrorsShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	out, err := sr.callToolWithTimeout("k8s_get_events", map[string]interface{}{"namespace": "all"})
	if err != nil {
		return nil, err
	}

	// Filter to Warning lines only
	lines := strings.Split(out, "\n")
	var warnings []string
	for _, line := range lines {
		if strings.Contains(line, "Warning") || strings.Contains(line, "WARN") {
			warnings = append(warnings, line)
		}
	}

	// Time-based filtering: keep only events from last 15 minutes
	recentWarnings := filterRecentEvents(warnings, 15*time.Minute)

	// Deduplicate events
	deduped := deduplicateEvents(recentWarnings)

	status := fmt.Sprintf("%d unique warning events (last 15m)", len(deduped))
	var details string
	if len(deduped) > 0 {
		max := 20
		if len(deduped) < max {
			max = len(deduped)
		}
		var detailLines []string
		for _, de := range deduped[:max] {
			detailLines = append(detailLines, de.Summary())
		}
		details = strings.Join(detailLines, "\n")
		if len(deduped) > 20 {
			details += fmt.Sprintf("\n[...%d more unique events]", len(deduped)-20)
		}
	} else {
		details = "No warning events in last 15 minutes."
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "errors",
		Status:    status,
		Details:   details,
		Followups: []string{"health", "restarts", "pods"},
	}, nil
}

func handleTopShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{
		"resource_type":  "pod",
		"all_namespaces": "true",
	})
	if err != nil {
		return nil, err
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "top",
		Status:    "Pod resource overview (sorted by status)",
		Details:   out,
		Followups: []string{"nodes", "errors", "health"},
	}, nil
}

func handleNodesShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "node"})
	if err != nil {
		return nil, err
	}

	lines := strings.Split(out, "\n")
	readyCount := 0
	totalCount := 0
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		totalCount++
		if strings.Contains(line, "Ready") && !strings.Contains(line, "NotReady") {
			readyCount++
		}
	}

	status := fmt.Sprintf("%d/%d nodes Ready", readyCount, totalCount)
	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "nodes",
		Status:    status,
		Details:   out,
		Followups: []string{"health", "pods", "top"},
	}, nil
}

func handleRestartsShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{
		"resource_type":  "pod",
		"all_namespaces": "true",
	})
	if err != nil {
		return nil, err
	}

	lines := strings.Split(out, "\n")
	var header string
	var restarted []string
	for i, line := range lines {
		if i == 0 {
			header = line
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 5 {
			restarts := fields[4]
			if restarts != "0" && restarts != "RESTARTS" {
				restarted = append(restarted, line)
			}
		}
	}

	status := fmt.Sprintf("%d pods with restarts", len(restarted))
	details := header + "\n"
	if len(restarted) > 0 {
		details += strings.Join(restarted, "\n")
	} else {
		details += "(none)"
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "restarts",
		Status:    status,
		Details:   details,
		Followups: []string{"errors", "health", "pods"},
	}, nil
}

// handleLogsShortcut retrieves tail logs for a pod — bypasses LLM entirely.
// Usage: logs <pod> [namespace] [container]
func handleLogsShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	parts := strings.Fields(query)
	if len(parts) < 2 {
		return nil, fmt.Errorf("usage: logs <pod> [namespace] [container]")
	}
	podName := parts[1]
	ns := ""
	container := ""
	if len(parts) >= 3 {
		ns = parts[2]
	}
	if len(parts) >= 4 {
		container = parts[3]
	}

	args := map[string]interface{}{
		"pod_name":   podName,
		"tail_lines": 50,
	}
	if ns != "" {
		args["namespace"] = ns
	}
	if container != "" {
		args["container"] = container
	}

	out, err := sr.callToolWithTimeout("k8s_get_pod_logs", args)
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "container") || strings.Contains(errStr, "must specify") {
			return &shortcutResponse{
				Type:      "shortcut",
				Query:     fmt.Sprintf("logs %s", podName),
				Status:    fmt.Sprintf("Pod %s has multiple containers — specify one", podName),
				Details:   errStr,
				Followups: []string{fmt.Sprintf("pod %s", podName), "pods", "errors"},
			}, nil
		}
		return nil, err
	}

	logLines := strings.Split(out, "\n")
	errorCount := 0
	for _, line := range logLines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "error") || strings.Contains(lower, "fatal") ||
			strings.Contains(lower, "panic") || strings.Contains(lower, "exception") {
			errorCount++
		}
	}

	status := fmt.Sprintf("Pod %s: %d log lines (tail 50)", podName, len(logLines))
	if errorCount > 0 {
		status += fmt.Sprintf(", %d error/fatal lines", errorCount)
	}

	followups := []string{fmt.Sprintf("pod %s", podName), "errors"}
	if ns != "" {
		followups = append(followups, fmt.Sprintf("ns %s", ns))
	} else {
		followups = append(followups, "pods")
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     fmt.Sprintf("logs %s", podName),
		Status:    status,
		Details:   out,
		Followups: followups,
	}, nil
}

// handleDeployShortcut shows deployment rollout status, conditions, and failing pods.
// Usage: deploy <name> [namespace]
func handleDeployShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	parts := strings.Fields(query)
	if len(parts) < 2 {
		return nil, fmt.Errorf("usage: deploy <name> [namespace]")
	}
	deployName := parts[1]
	ns := ""
	if len(parts) >= 3 {
		ns = parts[2]
	}

	type result struct {
		key  string
		data string
		err  error
	}
	results := make(chan result, 2)
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		args := map[string]interface{}{
			"resource_type": "deployment",
			"resource_name": deployName,
		}
		if ns != "" {
			args["namespace"] = ns
		}
		out, err := sr.callToolWithTimeout("k8s_describe_resource", args)
		results <- result{"describe", out, err}
	}()

	wg.Add(1)
	go func() {
		defer wg.Done()
		evtNs := ns
		if evtNs == "" {
			evtNs = "default"
		}
		out, err := sr.callToolWithTimeout("k8s_get_events", map[string]interface{}{"namespace": evtNs})
		results <- result{"events", out, err}
	}()

	go func() { wg.Wait(); close(results) }()

	data := make(map[string]string)
	for r := range results {
		if r.err == nil {
			data[r.key] = r.data
		}
	}

	describeOut := data["describe"]
	eventsOut := data["events"]

	// Parse deployment describe output
	replicas := ""
	var conditionLines []string
	lines := strings.Split(describeOut, "\n")
	inConditions := false
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Replicas:") {
			replicas = trimmed
		}
		if strings.HasPrefix(trimmed, "Conditions:") {
			inConditions = true
			continue
		}
		if inConditions {
			if strings.Contains(trimmed, "True") || strings.Contains(trimmed, "False") ||
				strings.Contains(trimmed, "Available") || strings.Contains(trimmed, "Progressing") {
				conditionLines = append(conditionLines, trimmed)
			} else if trimmed == "" || strings.HasPrefix(trimmed, "OldReplicaSets") || strings.HasPrefix(trimmed, "NewReplicaSet") || strings.HasPrefix(trimmed, "Events") {
				inConditions = false
			}
		}
	}

	// Filter events related to this deployment
	var relevantEvents []string
	for _, line := range strings.Split(eventsOut, "\n") {
		if strings.Contains(line, deployName) && strings.Contains(line, "Warning") {
			relevantEvents = append(relevantEvents, line)
		}
	}

	status := fmt.Sprintf("Deployment %s: %s", deployName, replicas)
	if replicas == "" {
		status = fmt.Sprintf("Deployment %s described", deployName)
	}

	var detailParts []string
	if replicas != "" {
		detailParts = append(detailParts, replicas)
	}
	if len(conditionLines) > 0 {
		detailParts = append(detailParts, "Conditions:\n"+strings.Join(conditionLines, "\n"))
	}
	if len(relevantEvents) > 0 {
		max := 5
		if len(relevantEvents) < max {
			max = len(relevantEvents)
		}
		detailParts = append(detailParts, fmt.Sprintf("Recent warnings (%d):\n%s", len(relevantEvents), strings.Join(relevantEvents[:max], "\n")))
	}

	details := strings.Join(detailParts, "\n\n")
	if details == "" {
		details = describeOut
	}

	followups := []string{fmt.Sprintf("logs %s", deployName), "errors"}
	if ns != "" {
		followups = append(followups, fmt.Sprintf("ns %s", ns))
	} else {
		followups = append(followups, "pods")
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     fmt.Sprintf("deploy %s", deployName),
		Status:    status,
		Details:   details,
		Followups: followups,
	}, nil
}

func handleNamespaceShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	parts := strings.Fields(query)
	ns := "default"
	if len(parts) >= 2 {
		ns = strings.ToLower(parts[1])
	}

	out, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{
		"resource_type": "pod",
		"namespace":     ns,
	})
	if err != nil {
		return nil, err
	}

	lines := strings.Split(out, "\n")
	podCount := 0
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) != "" {
			podCount++
		}
	}

	status := fmt.Sprintf("Namespace %s: %d pods", ns, podCount)
	return &shortcutResponse{
		Type:      "shortcut",
		Query:     fmt.Sprintf("ns %s", ns),
		Status:    status,
		Details:   out,
		Followups: []string{"errors", fmt.Sprintf("events in %s", ns), "health"},
	}, nil
}

func handlePodsShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	parts := strings.Fields(query)
	args := map[string]interface{}{
		"resource_type":  "pod",
		"all_namespaces": "true",
	}
	if len(parts) >= 2 {
		args = map[string]interface{}{
			"resource_type": "pod",
			"namespace":     strings.ToLower(parts[1]),
		}
	}

	out, err := sr.callToolWithTimeout("k8s_get_resources", args)
	if err != nil {
		return nil, err
	}

	lines := strings.Split(out, "\n")
	running := 0
	completed := 0
	failing := 0
	for _, line := range lines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if strings.Contains(line, "Running") {
			running++
		} else if isCompletedPod(line) {
			completed++
		} else {
			failing++
		}
	}

	total := running + completed + failing
	status := fmt.Sprintf("%d pods running, %d completed, %d failing (total %d)", running, completed, failing, total)
	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "pods",
		Status:    status,
		Details:   out,
		Followups: []string{"restarts", "errors", "nodes"},
	}, nil
}

func handlePodShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	parts := strings.Fields(query)
	if len(parts) < 2 {
		return nil, fmt.Errorf("usage: pod <name> [namespace]")
	}
	podName := parts[1]
	ns := ""
	if len(parts) >= 3 {
		ns = parts[2]
	}

	args := map[string]interface{}{
		"resource_type": "pod",
		"resource_name": podName,
	}
	if ns != "" {
		args["namespace"] = ns
	}

	out, err := sr.callToolWithTimeout("k8s_describe_resource", args)
	if err != nil {
		return nil, err
	}

	status := fmt.Sprintf("Pod %s described", podName)
	lines := strings.Split(out, "\n")
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "Status:") {
			status = fmt.Sprintf("Pod %s: %s", podName, strings.TrimPrefix(trimmed, "Status:"))
			break
		}
	}

	followups := []string{fmt.Sprintf("logs %s", podName), "errors"}
	if ns != "" {
		followups = append(followups, fmt.Sprintf("ns %s", ns))
	} else {
		followups = append(followups, "pods")
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     fmt.Sprintf("pod %s", podName),
		Status:    strings.TrimSpace(status),
		Details:   out,
		Followups: followups,
	}, nil
}

// --- Deterministic Pod Crash Investigation Plan ---
// Trigger: "why is pod X crashing", "diagnose pod X", "crashloop X"
// Fixed workflow: describe → events → logs → correlate → synthesize
func handlePodCrashInvestigation(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	podName, ns := extractPodFromInvestigationQuery(query)
	if podName == "" {
		return nil, fmt.Errorf("usage: diagnose <pod> [namespace]")
	}

	// Step 1: Describe pod
	describeArgs := map[string]interface{}{
		"resource_type": "pod",
		"resource_name": podName,
	}
	if ns != "" {
		describeArgs["namespace"] = ns
	}
	describeOut, describeErr := sr.callToolWithTimeout("k8s_describe_resource", describeArgs)

	// Step 2: Get events
	eventsArgs := map[string]interface{}{"namespace": "all"}
	if ns != "" {
		eventsArgs["namespace"] = ns
	}
	eventsOut, _ := sr.callToolWithTimeout("k8s_get_events", eventsArgs)

	// Step 3: Get tail logs
	logsArgs := map[string]interface{}{
		"pod_name":   podName,
		"tail_lines": 50,
	}
	if ns != "" {
		logsArgs["namespace"] = ns
	}
	logsOut, _ := sr.callToolWithTimeout("k8s_get_pod_logs", logsArgs)

	if describeErr != nil {
		return &shortcutResponse{
			Type:      "shortcut",
			Query:     fmt.Sprintf("diagnose %s", podName),
			Status:    fmt.Sprintf("Cannot find pod %s", podName),
			Details:   describeErr.Error(),
			Followups: []string{"pods", "health", "errors"},
		}, nil
	}

	diagnosis := correlatePodFailure(describeOut, eventsOut, logsOut, podName)

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     fmt.Sprintf("diagnose %s", podName),
		Status:    diagnosis.Status,
		Details:   diagnosis.FullReport(),
		Followups: diagnosis.Followups,
	}, nil
}

// extractPodFromInvestigationQuery parses pod name from investigation triggers.
func extractPodFromInvestigationQuery(query string) (podName, namespace string) {
	lower := strings.ToLower(query)

	prefixes := []string{
		"why is pod ", "why pod ", "diagnose pod ",
		"diagnose ", "crashloop ",
		"why is ", "why ",
	}
	cleaned := lower
	for _, p := range prefixes {
		if strings.HasPrefix(cleaned, p) {
			cleaned = strings.TrimPrefix(cleaned, p)
			break
		}
	}

	suffixes := []string{" crashing", " failing", " not working", " not running", " crashloop", " crashloopbackoff"}
	for _, s := range suffixes {
		cleaned = strings.TrimSuffix(cleaned, s)
	}

	parts := strings.Fields(cleaned)
	if len(parts) == 0 {
		return "", ""
	}

	podName = parts[0]
	if len(parts) >= 2 {
		namespace = parts[1]
	}
	return podName, namespace
}

// podDiagnosis holds the result of correlating pod failure signals.
type podDiagnosis struct {
	Status    string
	Cause     string
	Evidence  []string
	Action    string
	Followups []string
}

func (d *podDiagnosis) FullReport() string {
	var parts []string
	parts = append(parts, "Status: "+d.Status)
	if d.Cause != "" {
		parts = append(parts, "Cause: "+d.Cause)
	}
	if len(d.Evidence) > 0 {
		parts = append(parts, "Evidence:")
		for _, e := range d.Evidence {
			parts = append(parts, "  - "+e)
		}
	}
	if d.Action != "" {
		parts = append(parts, "Action: "+d.Action)
	}
	return strings.Join(parts, "\n")
}

// correlatePodFailure analyzes describe/events/logs for known failure patterns.
func correlatePodFailure(describeOut, eventsOut, logsOut, podName string) *podDiagnosis {
	diag := &podDiagnosis{
		Followups: []string{fmt.Sprintf("logs %s", podName), "errors", "health"},
	}

	describeLower := strings.ToLower(describeOut)
	eventsLower := strings.ToLower(eventsOut)
	logsLower := strings.ToLower(logsOut)

	// Pattern: OOMKilled
	if strings.Contains(describeLower, "oomkilled") {
		diag.Status = fmt.Sprintf("Pod %s: OOMKilled", podName)
		diag.Cause = "Container exceeded memory limit and was killed by the kernel."
		for _, line := range strings.Split(describeOut, "\n") {
			trimmed := strings.TrimSpace(line)
			if strings.Contains(strings.ToLower(trimmed), "memory") && (strings.Contains(trimmed, "limit") || strings.Contains(trimmed, "Limits")) {
				diag.Evidence = append(diag.Evidence, trimmed)
			}
		}
		diag.Action = "Increase memory limit in the pod spec or optimize application memory usage."
		return diag
	}

	// Pattern: ImagePullBackOff
	if strings.Contains(describeLower, "imagepullbackoff") || strings.Contains(describeLower, "errimagepull") {
		diag.Status = fmt.Sprintf("Pod %s: ImagePullBackOff", podName)
		diag.Cause = "Container image cannot be pulled — image not found, tag missing, or registry auth failed."
		for _, line := range strings.Split(describeOut, "\n") {
			if strings.Contains(strings.ToLower(line), "image") && (strings.Contains(line, ":") || strings.Contains(line, "/")) {
				diag.Evidence = append(diag.Evidence, strings.TrimSpace(line))
				break
			}
		}
		for _, line := range strings.Split(eventsOut, "\n") {
			if strings.Contains(strings.ToLower(line), "pull") && strings.Contains(strings.ToLower(line), podName) {
				diag.Evidence = append(diag.Evidence, strings.TrimSpace(line))
				break
			}
		}
		diag.Action = "Verify image name/tag exists, check registry credentials (imagePullSecrets)."
		return diag
	}

	// Pattern: CrashLoopBackOff
	if strings.Contains(describeLower, "crashloopbackoff") {
		diag.Status = fmt.Sprintf("Pod %s: CrashLoopBackOff", podName)
		exitCode := ""
		for _, line := range strings.Split(describeOut, "\n") {
			if strings.Contains(strings.ToLower(line), "exit code") {
				exitCode = strings.TrimSpace(line)
				diag.Evidence = append(diag.Evidence, exitCode)
				break
			}
		}
		if logsOut != "" {
			for _, line := range strings.Split(logsOut, "\n") {
				lower := strings.ToLower(line)
				if strings.Contains(lower, "error") || strings.Contains(lower, "fatal") || strings.Contains(lower, "panic") {
					diag.Evidence = append(diag.Evidence, "Log: "+strings.TrimSpace(line))
					if len(diag.Evidence) >= 5 {
						break
					}
				}
			}
		}
		if strings.Contains(exitCode, "137") {
			diag.Cause = "Container killed by signal (likely OOM or external kill)."
			diag.Action = "Check memory limits and node memory pressure."
		} else if strings.Contains(exitCode, "1") {
			diag.Cause = "Container exited with error code 1 — application startup failure."
			diag.Action = "Check application logs and configuration."
		} else {
			diag.Cause = "Container crashes repeatedly on startup."
			diag.Action = "Check container logs for startup errors, verify configuration and dependencies."
		}
		diag.Followups = []string{fmt.Sprintf("logs %s", podName), fmt.Sprintf("pod %s", podName), "errors"}
		return diag
	}

	// Pattern: Pending (scheduling failure)
	if strings.Contains(describeLower, "pending") {
		diag.Status = fmt.Sprintf("Pod %s: Pending (not scheduled)", podName)
		for _, line := range strings.Split(eventsOut, "\n") {
			lower := strings.ToLower(line)
			if (strings.Contains(lower, "failedscheduling") || strings.Contains(lower, "unschedulable")) &&
				strings.Contains(strings.ToLower(line), podName) {
				diag.Evidence = append(diag.Evidence, strings.TrimSpace(line))
				break
			}
		}
		if strings.Contains(eventsLower, "insufficient") {
			diag.Cause = "Insufficient cluster resources (CPU/memory) to schedule pod."
			diag.Action = "Reduce resource requests or add cluster capacity."
		} else if strings.Contains(eventsLower, "nodeselector") || strings.Contains(describeLower, "nodeselector") {
			diag.Cause = "No node matches pod's nodeSelector/affinity constraints."
			diag.Action = "Check nodeSelector labels match available nodes."
		} else {
			diag.Cause = "Pod cannot be scheduled — check node resources and constraints."
			diag.Action = "Run 'nodes' to check node status and available resources."
		}
		return diag
	}

	// Pattern: Probe failures
	if strings.Contains(eventsLower, "unhealthy") || strings.Contains(eventsLower, "probe failed") {
		diag.Status = fmt.Sprintf("Pod %s: Probe failures detected", podName)
		for _, line := range strings.Split(eventsOut, "\n") {
			lower := strings.ToLower(line)
			if (strings.Contains(lower, "unhealthy") || strings.Contains(lower, "probe")) &&
				strings.Contains(strings.ToLower(line), podName) {
				diag.Evidence = append(diag.Evidence, strings.TrimSpace(line))
				if len(diag.Evidence) >= 3 {
					break
				}
			}
		}
		if strings.Contains(eventsLower, "liveness") {
			diag.Cause = "Liveness probe failing — container is being restarted."
			diag.Action = "Check if the application is hanging or if probe configuration is too aggressive."
		} else {
			diag.Cause = "Readiness probe failing — pod is not receiving traffic."
			diag.Action = "Check application startup time and readiness probe configuration."
		}
		return diag
	}

	// Pattern: Permission errors in logs
	if strings.Contains(logsLower, "permission denied") || strings.Contains(logsLower, "forbidden") ||
		strings.Contains(logsLower, "access denied") {
		diag.Status = fmt.Sprintf("Pod %s: Permission errors in logs", podName)
		diag.Cause = "Application encountering permission/access errors at runtime."
		for _, line := range strings.Split(logsOut, "\n") {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "permission") || strings.Contains(lower, "forbidden") || strings.Contains(lower, "access denied") {
				diag.Evidence = append(diag.Evidence, "Log: "+strings.TrimSpace(line))
				if len(diag.Evidence) >= 3 {
					break
				}
			}
		}
		diag.Action = "Check RBAC, SecurityContext, and file permissions."
		return diag
	}

	// Fallback: no known pattern matched
	diag.Status = fmt.Sprintf("Pod %s: Unable to determine specific failure cause", podName)
	diag.Cause = "No common failure pattern (OOM, ImagePull, CrashLoop, Scheduling, Probe) detected."
	if logsOut != "" {
		for _, line := range strings.Split(logsOut, "\n") {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "error") || strings.Contains(lower, "fatal") {
				diag.Evidence = append(diag.Evidence, "Log: "+strings.TrimSpace(line))
				if len(diag.Evidence) >= 3 {
					break
				}
			}
		}
	}
	diag.Action = "Review full pod describe output and logs manually."
	return diag
}

// --- Event Deduplication ---

// dedupedEvent represents a group of deduplicated events.
type dedupedEvent struct {
	Reason  string
	Object  string
	Message string
	Count   int
}

// Summary returns a concise one-line summary of the deduplicated event.
func (de *dedupedEvent) Summary() string {
	if de.Count > 1 {
		return fmt.Sprintf("[x%d] %s — %s: %s", de.Count, de.Object, de.Reason, de.Message)
	}
	return fmt.Sprintf("%s — %s: %s", de.Object, de.Reason, de.Message)
}

// deduplicateEvents groups identical events by reason+object, counting occurrences.
func deduplicateEvents(lines []string) []*dedupedEvent {
	type eventKey struct {
		reason string
		object string
	}
	groups := make(map[eventKey]*dedupedEvent)
	var order []eventKey

	for _, line := range lines {
		reason, object, message := parseEventLine(line)
		if reason == "" {
			continue
		}
		key := eventKey{reason: reason, object: object}
		if existing, ok := groups[key]; ok {
			existing.Count++
		} else {
			groups[key] = &dedupedEvent{
				Reason:  reason,
				Object:  object,
				Message: message,
				Count:   1,
			}
			order = append(order, key)
		}
	}

	// Sort by count (most frequent first)
	sort.Slice(order, func(i, j int) bool {
		return groups[order[i]].Count > groups[order[j]].Count
	})

	var result []*dedupedEvent
	for _, key := range order {
		result = append(result, groups[key])
	}
	return result
}

// parseEventLine extracts reason, object, and message from a kubectl event line.
func parseEventLine(line string) (reason, object, message string) {
	fields := strings.Fields(line)
	if len(fields) < 5 {
		return "", "", ""
	}

	typeIdx := -1
	for i, f := range fields {
		if f == "Warning" || f == "Normal" || f == "WARN" {
			typeIdx = i
			break
		}
	}

	if typeIdx < 0 || typeIdx+2 >= len(fields) {
		return "", "", ""
	}

	reason = fields[typeIdx+1]
	object = fields[typeIdx+2]
	if typeIdx+3 < len(fields) {
		message = strings.Join(fields[typeIdx+3:], " ")
		if len(message) > 80 {
			message = message[:80] + "..."
		}
	}

	return reason, object, message
}

// filterRecentEvents filters event lines to those within the specified duration.
func filterRecentEvents(lines []string, maxAge time.Duration) []string {
	var recent []string
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		age := parseKubeAge(fields[0])
		if age > 0 && age <= maxAge {
			recent = append(recent, line)
		} else if age == 0 {
			// Could not parse age — include as fallback
			recent = append(recent, line)
		}
	}
	if len(recent) == 0 && len(lines) > 0 {
		return lines
	}
	return recent
}

// parseKubeAge parses kubectl-style age strings like "5m", "30s", "2h", "3d".
func parseKubeAge(s string) time.Duration {
	s = strings.TrimSpace(s)
	if s == "" || s == "<unknown>" {
		return 0
	}

	var total time.Duration
	current := ""
	for _, ch := range s {
		if ch >= '0' && ch <= '9' {
			current += string(ch)
		} else {
			if current == "" {
				continue
			}
			val := 0
			for _, d := range current {
				val = val*10 + int(d-'0')
			}
			switch ch {
			case 's':
				total += time.Duration(val) * time.Second
			case 'm':
				total += time.Duration(val) * time.Minute
			case 'h':
				total += time.Duration(val) * time.Hour
			case 'd':
				total += time.Duration(val) * 24 * time.Hour
			}
			current = ""
		}
	}
	return total
}

// --- Pod Status Helpers ---

// isCompletedPod returns true if a pod line indicates a completed/succeeded state.
func isCompletedPod(line string) bool {
	return strings.Contains(line, "Completed") || strings.Contains(line, "Succeeded")
}

// --- MCP Tool Call Helper ---

// callTool invokes a single MCP tool through the mcp-preprocessor (bounded output).
func (sr *shortcutRouter) callTool(toolName string, arguments map[string]interface{}) (string, error) {
	req := jsonrpcRequest{
		JSONRPC: "2.0",
		ID:      1,
		Method:  "tools/call",
		Params: toolCallParams{
			Name:      toolName,
			Arguments: arguments,
		},
	}

	body, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("marshal request: %w", err)
	}

	targetURL := *sr.mcpUpstream
	targetURL.Path = "/mcp"

	httpReq, err := http.NewRequest(http.MethodPost, targetURL.String(), bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("create request: %w", err)
	}
	httpReq.Header.Set("Content-Type", "application/json")

	resp, err := sr.client.Do(httpReq)
	if err != nil {
		return "", fmt.Errorf("upstream call: %w", err)
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("upstream returned %d: %s", resp.StatusCode, string(respBody))
	}

	var jsonResp struct {
		Result struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		} `json:"result"`
		Error json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(respBody, &jsonResp); err != nil {
		return string(respBody), nil
	}
	if jsonResp.Error != nil {
		return "", fmt.Errorf("tool error: %s", string(jsonResp.Error))
	}

	var texts []string
	for _, c := range jsonResp.Result.Content {
		if c.Type == "text" && c.Text != "" {
			texts = append(texts, c.Text)
		}
	}
	return strings.Join(texts, "\n"), nil
}

// --- Overview Summary Builder ---

type overviewResponse struct {
	Type       string   `json:"type"`
	Status     string   `json:"status"`
	Nodes      string   `json:"nodes"`
	Pods       string   `json:"pods"`
	Warnings   string   `json:"warnings"`
	Issues     []string `json:"issues,omitempty"`
	Details    string   `json:"details"`
	Elapsed    string   `json:"elapsed"`
	Followups  []string `json:"followups"`
	Confidence string   `json:"confidence"` // "high", "partial", "low"
}

func buildOverviewSummary(nodesOutput, podsOutput, eventsOutput string) *overviewResponse {
	nodeLines := strings.Split(nodesOutput, "\n")
	totalNodes := 0
	readyNodes := 0
	for _, line := range nodeLines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		totalNodes++
		if strings.Contains(line, "Ready") && !strings.Contains(line, "NotReady") {
			readyNodes++
		}
	}

	// Count pods — exclude Completed/Succeeded from unhealthy count
	podLines := strings.Split(podsOutput, "\n")
	totalPods := 0
	healthyPods := 0
	var failingPods []string
	for _, line := range podLines[1:] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		totalPods++
		if strings.Contains(line, "Running") {
			healthyPods++
		} else if isCompletedPod(line) {
			healthyPods++
		} else if strings.Contains(line, "CrashLoopBackOff") ||
			strings.Contains(line, "Error") ||
			strings.Contains(line, "ImagePullBackOff") ||
			strings.Contains(line, "Pending") {
			fields := strings.Fields(line)
			if len(fields) >= 4 {
				failingPods = append(failingPods, fmt.Sprintf("%s (%s)", fields[1], fields[3]))
			}
		} else {
			// Init, ContainerCreating, etc. — not failing
			healthyPods++
		}
	}

	// Count warnings filtered to last 15m
	eventLines := strings.Split(eventsOutput, "\n")
	var warningLines []string
	for _, line := range eventLines {
		if strings.Contains(line, "Warning") {
			warningLines = append(warningLines, line)
		}
	}
	recentWarnings := filterRecentEvents(warningLines, 15*time.Minute)
	warningCount := len(recentWarnings)

	clusterState := "healthy"
	if readyNodes < totalNodes || len(failingPods) > 0 {
		clusterState = "degraded"
	}

	status := fmt.Sprintf("Cluster: %s. %d/%d nodes ready, %d/%d pods healthy, %d warnings (15m).",
		clusterState, readyNodes, totalNodes, healthyPods, totalPods, warningCount)

	var issues []string
	if readyNodes < totalNodes {
		issues = append(issues, fmt.Sprintf("%d node(s) not ready", totalNodes-readyNodes))
	}
	for _, fp := range failingPods {
		issues = append(issues, fp)
		if len(issues) >= 5 {
			break
		}
	}

	followups := []string{"errors", "top", "nodes"}
	if len(failingPods) > 0 {
		fields := strings.Fields(failingPods[0])
		if len(fields) > 0 {
			podNameOnly := strings.Split(fields[0], " ")[0]
			followups = []string{fmt.Sprintf("diagnose %s", podNameOnly), "errors", "restarts"}
		}
	}

	return &overviewResponse{
		Type:       "overview",
		Status:     status,
		Nodes:      fmt.Sprintf("%d/%d ready", readyNodes, totalNodes),
		Pods:       fmt.Sprintf("%d/%d healthy", healthyPods, totalPods),
		Warnings:   fmt.Sprintf("%d", warningCount),
		Issues:     issues,
		Details:    status,
		Followups:  followups,
		Confidence: "high",
	}
}

// jsonrpcRequest and toolCallParams are re-used types.
type jsonrpcRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params,omitempty"`
}

type toolCallParams struct {
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments,omitempty"`
}

// recordShortcut records a shortcut invocation metric.
func recordShortcut(pattern string, duration time.Duration) {
	a2aMetrics.requestsTotal.Inc(fmt.Sprintf(`status="2xx",type="shortcut",pattern="%s"`, pattern))
	a2aMetrics.requestDuration.Observe(fmt.Sprintf(`type="shortcut"`), duration.Seconds())
}
