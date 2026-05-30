// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Resilience — graceful degradation, structured errors, health probes,
// Ollama reachability monitoring, and the "status" shortcut.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// --- Per-Tool-Call Timeout ---

// toolCallTimeout is the maximum duration for any single MCP tool call.
// No retries — a failed call returns a structured timeout result immediately.
const toolCallTimeout = 10 * time.Second


// callToolWithTimeout invokes callTool with per-call timeout enforcement.
// Returns empty string and error on timeout — never hangs.
// Timeout does not block entire workflow; parallel calls continue independently.
func (sr *shortcutRouter) callToolWithTimeout(toolName string, arguments map[string]interface{}) (string, error) {
	type result struct {
		data string
		err  error
	}
	ch := make(chan result, 1)
	start := time.Now()
	go func() {
		data, err := sr.callTool(toolName, arguments)
		ch <- result{data, err}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), toolCallTimeout)
	defer cancel()

	select {
	case r := <-ch:
		return r.data, r.err
	case <-ctx.Done():
		elapsed := time.Since(start)
		return "", fmt.Errorf("tool_timeout: %s did not respond within %s (elapsed: %s)", toolName, toolCallTimeout, elapsed.Round(time.Millisecond))
	}
}

// --- Structured Error Response ---

// Error categories (enum)
const (
	ErrOllamaUnreachable     = "ollama_unreachable"
	ErrToolTimeout           = "tool_timeout"
	ErrRBACDenied            = "rbac_denied"
	ErrKubernetesUnreachable = "kubernetes_api_unreachable"
	ErrResourceNotFound      = "resource_not_found"
	ErrPreprocessingFailure  = "preprocessing_failure"
)

// structuredError represents a deterministic, operator-friendly error.
// Every failure response includes all fields for full observability.
type structuredError struct {
	Type               string   `json:"type"`                // "error"
	Status             string   `json:"status"`              // one-line summary
	Component          string   `json:"component"`           // which component failed
	Reason             string   `json:"reason"`              // error category enum
	FailureReason      string   `json:"failure_reason"`      // specific failure detail
	Impact             string   `json:"impact"`              // what's affected
	AvailableWorkflows []string `json:"available_workflows"` // what still works
	SuggestedActions   []string `json:"suggested_actions"`   // what user can try
	Elapsed            string   `json:"elapsed"`             // response time
	RequestID          string   `json:"requestId"`           // correlation ID
	Confidence         string   `json:"confidence"`          // "high", "partial", "low"
}

// availableShortcuts returns the list of deterministic shortcuts that work without LLM.
func availableShortcuts() []string {
	return []string{"health", "errors", "nodes", "pods", "logs <pod>", "deploy <name>", "diagnose <pod>", "status"}
}

// newStructuredError creates a structured error with defaults.
func newStructuredError(component, reason, impact string, elapsed time.Duration) *structuredError {
	return &structuredError{
		Type:               "error",
		Status:             fmt.Sprintf("%s: %s", component, reason),
		Component:          component,
		Reason:             classifyErrorCategory(component, reason),
		FailureReason:      reason,
		Impact:             impact,
		AvailableWorkflows: availableShortcuts(),
		SuggestedActions:   []string{"Try: health", "Try: errors", "Try: status"},
		Elapsed:            fmt.Sprintf("%.1fs", elapsed.Seconds()),
		RequestID:          "",
		Confidence:         "low",
	}
}

// classifyErrorCategory maps component+reason to a structured error category.
func classifyErrorCategory(component, reason string) string {
	lower := strings.ToLower(reason)
	switch {
	case strings.Contains(lower, "ollama"):
		return ErrOllamaUnreachable
	case strings.Contains(lower, "timeout"):
		return ErrToolTimeout
	case strings.Contains(lower, "rbac") || strings.Contains(lower, "forbidden"):
		return ErrRBACDenied
	case component == "kubernetes-api" && strings.Contains(lower, "not found"):
		return ErrResourceNotFound
	case component == "kubernetes-api":
		return ErrKubernetesUnreachable
	case component == "mcp-preprocessor":
		return ErrPreprocessingFailure
	default:
		return ErrToolTimeout
	}
}

// writeStructuredError writes a structured error as JSON to the response.
func writeStructuredError(w http.ResponseWriter, statusCode int, se *structuredError) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(statusCode)
	json.NewEncoder(w).Encode(se)
}

// --- Ollama Reachability Monitor ---

// ollamaMonitor tracks Ollama connectivity state.
type ollamaMonitor struct {
	ollamaURL   string
	reachable   atomic.Int64 // 1=reachable, 0=unreachable
	lastLatency atomic.Int64 // microseconds
	lastCheck   atomic.Int64 // unix timestamp
	lastError   atomic.Value // string
	client      *http.Client
}

var globalOllamaMonitor *ollamaMonitor

// newOllamaMonitor creates and starts the background Ollama monitor.
func newOllamaMonitor(ollamaURL string) *ollamaMonitor {
	m := &ollamaMonitor{
		ollamaURL: ollamaURL,
		client: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
	m.lastError.Store("")
	// Initial probe
	m.probe()
	// Background polling every 30s
	go func() {
		ticker := time.NewTicker(30 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			m.probe()
		}
	}()
	globalOllamaMonitor = m
	return m
}

// probe checks Ollama reachability via its API endpoint.
func (m *ollamaMonitor) probe() {
	start := time.Now()
	resp, err := m.client.Get(m.ollamaURL + "/api/tags")
	latency := time.Since(start)

	m.lastCheck.Store(time.Now().Unix())
	m.lastLatency.Store(latency.Microseconds())

	if err != nil {
		m.reachable.Store(0)
		errMsg := err.Error()
		if strings.Contains(errMsg, "refused") {
			m.lastError.Store("connection refused")
		} else if strings.Contains(errMsg, "timeout") || strings.Contains(errMsg, "deadline") {
			m.lastError.Store("timeout")
		} else if strings.Contains(errMsg, "no such host") || strings.Contains(errMsg, "DNS") {
			m.lastError.Store("DNS failure")
		} else {
			m.lastError.Store(errMsg)
		}
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		m.reachable.Store(1)
		m.lastError.Store("")
	} else {
		m.reachable.Store(0)
		m.lastError.Store(fmt.Sprintf("HTTP %d", resp.StatusCode))
	}
}

// isReachable returns current Ollama reachability state.
func (m *ollamaMonitor) isReachable() bool {
	return m.reachable.Load() == 1
}

// statusString returns "reachable" or "unreachable (reason)".
func (m *ollamaMonitor) statusString() string {
	if m.isReachable() {
		return "reachable"
	}
	errStr, _ := m.lastError.Load().(string)
	if errStr != "" {
		return fmt.Sprintf("unreachable (%s)", errStr)
	}
	return "unreachable"
}

// latencyMs returns last probe latency in milliseconds.
func (m *ollamaMonitor) latencyMs() int64 {
	return m.lastLatency.Load() / 1000
}

// --- /readyz Endpoint ---

// readyzResponse represents the structured readiness check.
type readyzResponse struct {
	Status                  string                `json:"status"` // "ready", "degraded", "unavailable"
	Components              map[string]compStatus `json:"components"`
	Timestamp               string                `json:"timestamp"`
	Elapsed                 string                `json:"elapsed"`
	LastSuccessfulOllamaProbe string              `json:"lastSuccessfulOllamaProbe,omitempty"`
	DegradedCapabilities    []string              `json:"degradedCapabilities,omitempty"`
}

type compStatus struct {
	Status       string `json:"status"`        // "healthy", "degraded", "unavailable"
	Latency      string `json:"latency"`       // response time
	Error        string `json:"error,omitempty"`
	ResponseTime string `json:"responseTime,omitempty"` // explicit ms value
}

func (sr *shortcutRouter) handleReadyz(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	components := make(map[string]compStatus)

	// Check mcp-preprocessor
	mcpStart := time.Now()
	mcpURL := *sr.mcpUpstream
	mcpURL.Path = "/healthz"
	mcpResp, mcpErr := sr.client.Get(mcpURL.String())
	mcpLatency := time.Since(mcpStart)
	if mcpErr != nil {
		components["mcp-preprocessor"] = compStatus{Status: "unavailable", Latency: mcpLatency.String(), Error: mcpErr.Error(), ResponseTime: fmt.Sprintf("%dms", mcpLatency.Milliseconds())}
	} else {
		mcpResp.Body.Close()
		if mcpResp.StatusCode == http.StatusOK {
			components["mcp-preprocessor"] = compStatus{Status: "healthy", Latency: mcpLatency.String(), ResponseTime: fmt.Sprintf("%dms", mcpLatency.Milliseconds())}
		} else {
			components["mcp-preprocessor"] = compStatus{Status: "degraded", Latency: mcpLatency.String(), Error: fmt.Sprintf("HTTP %d", mcpResp.StatusCode), ResponseTime: fmt.Sprintf("%dms", mcpLatency.Milliseconds())}
		}
	}

	// Check Ollama (from monitor)
	var lastSuccessfulProbe string
	var degradedCapabilities []string
	if globalOllamaMonitor != nil {
		if globalOllamaMonitor.isReachable() {
			components["ollama"] = compStatus{Status: "healthy", Latency: fmt.Sprintf("%dms", globalOllamaMonitor.latencyMs()), ResponseTime: fmt.Sprintf("%dms", globalOllamaMonitor.latencyMs())}
			lastSuccessfulProbe = time.Unix(globalOllamaMonitor.lastCheck.Load(), 0).UTC().Format(time.RFC3339)
		} else {
			errStr := globalOllamaMonitor.statusString()
			components["ollama"] = compStatus{Status: "unavailable", Latency: "N/A", Error: errStr}
			degradedCapabilities = append(degradedCapabilities, "LLM inference", "free-form queries", "complex analysis")
			// Find last successful probe from lastCheck when it was reachable
			lastCheck := globalOllamaMonitor.lastCheck.Load()
			if lastCheck > 0 {
				lastSuccessfulProbe = time.Unix(lastCheck, 0).UTC().Format(time.RFC3339) + " (last attempt, was unreachable)"
			}
		}
	} else {
		components["ollama"] = compStatus{Status: "unknown", Latency: "N/A", Error: "monitor not initialized"}
	}

	// Check k2s-tools via a lightweight tool call (fastest possible — just connect)
	toolStart := time.Now()
	_, toolErr := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "namespace"})
	toolLatency := time.Since(toolStart)
	if toolErr != nil {
		if strings.Contains(toolErr.Error(), "timeout") {
			components["k2s-tools"] = compStatus{Status: "unavailable", Latency: toolLatency.String(), Error: "timeout", ResponseTime: fmt.Sprintf("%dms", toolLatency.Milliseconds())}
		} else {
			components["k2s-tools"] = compStatus{Status: "degraded", Latency: toolLatency.String(), Error: toolErr.Error(), ResponseTime: fmt.Sprintf("%dms", toolLatency.Milliseconds())}
		}
		degradedCapabilities = append(degradedCapabilities, "kubectl operations", "cluster inspection")
	} else {
		components["k2s-tools"] = compStatus{Status: "healthy", Latency: toolLatency.String(), ResponseTime: fmt.Sprintf("%dms", toolLatency.Milliseconds())}
	}

	// Determine overall status
	overallStatus := "ready"
	for _, cs := range components {
		if cs.Status == "unavailable" {
			overallStatus = "degraded"
		}
	}
	// If k2s-tools and mcp-preprocessor both down, we're unavailable
	if components["mcp-preprocessor"].Status == "unavailable" && components["k2s-tools"].Status == "unavailable" {
		overallStatus = "unavailable"
	}

	resp := readyzResponse{
		Status:                    overallStatus,
		Components:                components,
		Timestamp:                 time.Now().UTC().Format(time.RFC3339),
		Elapsed:                   fmt.Sprintf("%.1fs", time.Since(start).Seconds()),
		LastSuccessfulOllamaProbe: lastSuccessfulProbe,
		DegradedCapabilities:      degradedCapabilities,
	}

	w.Header().Set("Content-Type", "application/json")
	if overallStatus == "unavailable" {
		w.WriteHeader(http.StatusServiceUnavailable)
	} else {
		w.WriteHeader(http.StatusOK)
	}
	json.NewEncoder(w).Encode(resp)
}

// --- Status Shortcut ---

func handleStatusShortcut(sr *shortcutRouter, query string) (*shortcutResponse, error) {
	type probeResult struct {
		name    string
		status  string
		latency time.Duration
		err     string
	}

	results := make(chan probeResult, 4)
	var wg sync.WaitGroup

	// Probe mcp-preprocessor
	wg.Add(1)
	go func() {
		defer wg.Done()
		start := time.Now()
		mcpURL := *sr.mcpUpstream
		mcpURL.Path = "/healthz"
		resp, err := sr.client.Get(mcpURL.String())
		latency := time.Since(start)
		if err != nil {
			results <- probeResult{"mcp-preprocessor", "unavailable", latency, err.Error()}
			return
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			results <- probeResult{"mcp-preprocessor", "healthy", latency, ""}
		} else {
			results <- probeResult{"mcp-preprocessor", "degraded", latency, fmt.Sprintf("HTTP %d", resp.StatusCode)}
		}
	}()

	// Probe k2s-tools (via namespace list — lightweight)
	wg.Add(1)
	go func() {
		defer wg.Done()
		start := time.Now()
		_, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "namespace"})
		latency := time.Since(start)
		if err != nil {
			results <- probeResult{"k2s-tools", "unavailable", latency, err.Error()}
		} else {
			results <- probeResult{"k2s-tools", "healthy", latency, ""}
		}
	}()

	// Probe Kubernetes API (implicitly tested by k2s-tools, but check nodes for direct validation)
	wg.Add(1)
	go func() {
		defer wg.Done()
		start := time.Now()
		_, err := sr.callToolWithTimeout("k8s_get_resources", map[string]interface{}{"resource_type": "node"})
		latency := time.Since(start)
		if err != nil {
			results <- probeResult{"kubernetes-api", "unavailable", latency, err.Error()}
		} else {
			results <- probeResult{"kubernetes-api", "healthy", latency, ""}
		}
	}()

	// Ollama status from monitor
	wg.Add(1)
	go func() {
		defer wg.Done()
		if globalOllamaMonitor != nil {
			latencyMs := globalOllamaMonitor.latencyMs()
			if globalOllamaMonitor.isReachable() {
				results <- probeResult{"ollama", "healthy", time.Duration(latencyMs) * time.Millisecond, ""}
			} else {
				results <- probeResult{"ollama", "unavailable", 0, globalOllamaMonitor.statusString()}
			}
		} else {
			results <- probeResult{"ollama", "unknown", 0, "monitor not initialized"}
		}
	}()

	go func() { wg.Wait(); close(results) }()

	// Collect
	var lines []string
	overallHealthy := true
	ollamaReachable := true
	for r := range results {
		line := fmt.Sprintf("%s: %s (%dms)", r.name, r.status, r.latency.Milliseconds())
		if r.err != "" {
			line += fmt.Sprintf(" — %s", r.err)
		}
		lines = append(lines, line)
		if r.status != "healthy" {
			overallHealthy = false
		}
		if r.name == "ollama" && r.status != "healthy" {
			ollamaReachable = false
		}
	}

	overallStatus := "All systems operational."
	if !overallHealthy {
		overallStatus = "Degraded — some components unavailable."
	}

	// Ollama degradation messaging — explicit, actionable
	if !ollamaReachable {
		overallStatus += "\n\nAI inference unavailable (Ollama unreachable).\nDeterministic workflows still operational:\n• health\n• errors\n• logs <pod>\n• deploy <name>\n• diagnose <pod>\n• nodes\n• pods\n• status"
	}

	// Available workflows during degradation
	var detailParts []string
	detailParts = append(detailParts, strings.Join(lines, "\n"))

	if !overallHealthy {
		detailParts = append(detailParts, "\nAvailable workflows during degradation:")
		for _, s := range availableShortcuts() {
			detailParts = append(detailParts, fmt.Sprintf("  • %s", s))
		}
	}

	return &shortcutResponse{
		Type:      "shortcut",
		Query:     "status",
		Status:    overallStatus,
		Details:   strings.Join(detailParts, "\n"),
		Followups: []string{"health", "errors", "nodes"},
	}, nil
}

// --- Partial Result Annotations ---


// computeConfidence determines data confidence based on failures.
// Returns "high" (all sources ok), "partial" (some failed), "low" (most failed).
func computeConfidence(totalSources, failedSources int) string {
	if failedSources == 0 {
		return "high"
	}
	if failedSources < totalSources {
		return "partial"
	}
	return "low"
}

// --- Ollama Metrics ---

// writeOllamaMetric writes the Ollama reachability gauge to the metrics output.
func writeOllamaMetric(sb *strings.Builder) {
	sb.WriteString("# HELP ai_assistant_ollama_reachable Whether Ollama is reachable (1=yes, 0=no)\n")
	sb.WriteString("# TYPE ai_assistant_ollama_reachable gauge\n")
	if globalOllamaMonitor != nil {
		fmt.Fprintf(sb, "ai_assistant_ollama_reachable %d\n", globalOllamaMonitor.reachable.Load())
	} else {
		sb.WriteString("ai_assistant_ollama_reachable 0\n")
	}
}

// --- Graceful Error for Shortcut Handler ---

// handleShortcutError produces a structured error response for shortcut failures.
func handleShortcutError(w http.ResponseWriter, err error, query string, start time.Time) {
	elapsed := time.Since(start)
	errStr := err.Error()

	var se *structuredError
	switch {
	case strings.Contains(errStr, "timeout") || strings.Contains(errStr, "tool_timeout"):
		se = newStructuredError("k2s-tools", "tool call timeout (10s)", "Query could not complete in time — Kubernetes API may be slow", elapsed)
		se.Reason = ErrToolTimeout
		se.SuggestedActions = []string{"Try again in a moment", "Try: status", "Try: nodes"}
	case strings.Contains(errStr, "connection refused"):
		se = newStructuredError("mcp-preprocessor", "connection refused", "Tool server is not running — shortcuts using tool calls unavailable", elapsed)
		se.Reason = ErrPreprocessingFailure
		se.SuggestedActions = []string{"Check: kubectl get pods -n kagent", "Try: status"}
	case strings.Contains(errStr, "forbidden") || strings.Contains(errStr, "Forbidden"):
		se = newStructuredError("kubernetes-api", "RBAC denied", "Tool calls rejected — ClusterRoleBinding may be missing", elapsed)
		se.Reason = ErrRBACDenied
		se.SuggestedActions = []string{"Check: kubectl get clusterrolebinding k2s-tools-reader-binding", "Try: status"}
	case strings.Contains(errStr, "not found"):
		se = newStructuredError("kubernetes-api", "resource not found", "Requested resource does not exist", elapsed)
		se.Reason = ErrResourceNotFound
		se.SuggestedActions = []string{"Try: pods", "Try: health", "Verify resource name"}
	default:
		se = newStructuredError("unknown", errStr, "Shortcut execution failed", elapsed)
	}

	// Populate requestId from response header if available
	if reqID := w.Header().Get("X-Request-Id"); reqID != "" {
		se.RequestID = reqID
	}

	writeStructuredError(w, http.StatusInternalServerError, se)
}


// --- Helpers for partial result annotation in overview ---

// buildOverviewWithPartialResults constructs overview even when some data sources failed.
// Never silently omits failed data — all failures are explicitly annotated.
func buildOverviewWithPartialResults(nodesOutput, podsOutput, eventsOutput string, nodesFailed, podsFailed, eventsFailed bool) *overviewResponse {
	resp := buildOverviewSummary(nodesOutput, podsOutput, eventsOutput)

	// Count failures for confidence
	failedCount := 0
	if nodesFailed {
		failedCount++
	}
	if podsFailed {
		failedCount++
	}
	if eventsFailed {
		failedCount++
	}

	// Annotate unavailable sections — never silently omit
	var annotations []string
	if nodesFailed {
		resp.Nodes = "unavailable"
		annotations = append(annotations, "node data unavailable")
	}
	if podsFailed {
		resp.Pods = "unavailable"
		annotations = append(annotations, "pod data unavailable")
	}
	if eventsFailed {
		resp.Warnings = "unavailable"
		annotations = append(annotations, "event data unavailable")
	}

	// Set confidence indicator
	resp.Confidence = computeConfidence(3, failedCount)

	if len(annotations) > 0 {
		resp.Status = fmt.Sprintf("Cluster: partial data (%s confidence). %s.", resp.Confidence, strings.Join(annotations, ", "))
		resp.Details = resp.Status
	}

	return resp
}

