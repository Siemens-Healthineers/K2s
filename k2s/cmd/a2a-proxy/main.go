// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// a2a-proxy is a lightweight reverse proxy for the Kagent A2A API that
// auto-confirms tool invocations for approved read-only Kubernetes tools.
//
// It sits between the ingress and the kagent-controller, transparently
// forwarding all requests. When the agent runtime returns "input-required"
// with a tool confirmation request for an approved tool, the proxy
// automatically sends the confirmation and returns the final response.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
)

const cliName = "a2a-proxy"

// approvedTools is the allowlist of MCP tools that may be auto-confirmed.
// These are strictly read-only Kubernetes inspection tools.
var approvedTools = map[string]bool{
	"k8s_get_resources":      true,
	"k8s_describe_resource":  true,
	"k8s_get_pod_logs":       true,
	"k8s_get_events":         true,
	"k8s_get_resource_yaml":  true,
}

func main() {
	listenAddr := flag.String("addr", ":8082", "proxy listen address")
	upstream := flag.String("upstream", "http://kagent-controller.kagent.svc.cluster.local:8083", "kagent controller URL")
	mcpUpstream := flag.String("mcp-upstream", "http://mcp-preprocessor.kagent.svc.cluster.local:8084", "mcp-preprocessor URL for shortcuts")
	ollamaURL := flag.String("ollama-url", "http://172.19.1.1:11434", "Ollama API URL for reachability monitoring")
	maxConfirmRetries := flag.Int("max-confirm-retries", 3, "maximum auto-confirmation attempts per task")
	flag.Parse()

	// Structured JSON logging
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	upstreamURL, err := url.Parse(*upstream)
	if err != nil {
		slog.Error("Invalid upstream URL", "url", *upstream, "error", err)
		os.Exit(1)
	}

	mcpUpstreamURL, err := url.Parse(*mcpUpstream)
	if err != nil {
		slog.Error("Invalid MCP upstream URL", "url", *mcpUpstream, "error", err)
		os.Exit(1)
	}

	proxy := &a2aProxy{
		upstream:          upstreamURL,
		maxConfirmRetries: *maxConfirmRetries,
		client: &http.Client{
			Timeout: 600 * time.Second,
		},
	}

	// Shortcut router — bypasses LLM, calls MCP tools directly
	scRouter := &shortcutRouter{
		mcpUpstream: mcpUpstreamURL,
		client: &http.Client{
			Timeout: 15 * time.Second,
		},
	}

	// AG-UI compatibility handler — bridges legacy Headlamp plugin to A2A/shortcuts
	aguiHandler := &aguiCompatHandler{
		upstream:    upstreamURL,
		mcpUpstream: mcpUpstreamURL,
		proxy:       proxy,
		scRouter:    scRouter,
		client: &http.Client{
			Timeout: 600 * time.Second,
		},
	}

	// Start Ollama reachability monitor (background, 30s interval)
	newOllamaMonitor(*ollamaURL)
	slog.Info("Ollama monitor started", "url", *ollamaURL)

	reverseProxy := httputil.NewSingleHostReverseProxy(upstreamURL)
	reverseProxy.FlushInterval = -1 // stream immediately

	mux := http.NewServeMux()
	// AG-UI compatibility — translates legacy Headlamp plugin requests to A2A/shortcuts
	mux.HandleFunc("/api/agui/chat", aguiHandler.handleAGUI)
	mux.HandleFunc("/api/agui/chat/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"ok"}`))
	})
	// Query shortcuts — deterministic fast-path, bypasses LLM
	mux.HandleFunc("/api/shortcuts", scRouter.handleShortcuts)
	// Cluster overview — parallel tool calls, no LLM
	mux.HandleFunc("/api/overview", scRouter.handleOverview)
	// A2A endpoints get special handling
	mux.HandleFunc("/api/a2a/", proxy.handleA2A)
	// Everything else passes through unchanged
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		reverseProxy.ServeHTTP(w, r)
	})
	// Health endpoint (liveness — always OK if process running)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	// Readiness endpoint — probes downstream dependencies
	mux.HandleFunc("/readyz", scRouter.handleReadyz)
	// Prometheus metrics endpoint
	mux.HandleFunc("/metrics", metricsHandler)

	slog.Info("a2a-proxy starting", "component", "a2a-proxy", "addr", *listenAddr, "upstream", *upstream, "mcpUpstream", *mcpUpstream, "ollamaURL", *ollamaURL)
	if err := http.ListenAndServe(*listenAddr, mux); err != nil {
		slog.Error("Server failed", "error", err)
		os.Exit(1)
	}
}

// a2aProxy handles A2A requests with auto-confirmation logic.
type a2aProxy struct {
	upstream          *url.URL
	maxConfirmRetries int
	client            *http.Client
}

// a2aRequest represents the JSON-RPC envelope for A2A.
type a2aRequest struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      interface{} `json:"id,omitempty"`
	Method  string      `json:"method"`
	Params  interface{} `json:"params"`
}

// a2aResponse represents the JSON-RPC response envelope.
type a2aResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

// taskResult represents the A2A task result.
type taskResult struct {
	ID      string     `json:"id"`
	Status  taskStatus `json:"status"`
	History []message  `json:"history,omitempty"`
}

type taskStatus struct {
	State   string  `json:"state"`
	Message *message `json:"message,omitempty"`
}

type message struct {
	Role  string `json:"role"`
	Parts []part `json:"parts"`
}

type part struct {
	Type     string `json:"type,omitempty"`
	Text     string `json:"text,omitempty"`
	ToolName string `json:"toolName,omitempty"`
	Name     string `json:"name,omitempty"`
}

func (p *a2aProxy) handleA2A(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// X-Request-Id propagation — generate if not present
	requestID := r.Header.Get("X-Request-Id")
	if requestID == "" {
		requestID = uuid.New().String()
	}
	r.Header.Set("X-Request-Id", requestID)
	w.Header().Set("X-Request-Id", requestID)

	if r.Method != http.MethodPost {
		// Non-POST (e.g. GET for agent card) — pass through
		p.forwardRaw(w, r)
		recordRequest("2xx", time.Since(start))
		return
	}

	// Read the request body
	body, err := io.ReadAll(r.Body)
	if err != nil {
		slog.Error("[A2AProxy] Failed to read request body", "error", err, "requestId", requestID)
		http.Error(w, "bad request", http.StatusBadRequest)
		recordRequest("4xx", time.Since(start))
		return
	}
	r.Body.Close()

	// Forward the original request to upstream
	resp, respBody, err := p.forwardToUpstream(r, body)
	if err != nil {
		slog.Error("[A2AProxy] Upstream request failed", "error", err, "requestId", requestID)
		http.Error(w, "upstream error", http.StatusBadGateway)
		recordRequest("5xx", time.Since(start))
		recordUpstreamError()
		return
	}

	// Check if response needs auto-confirmation
	finalBody := p.maybeAutoConfirm(r, body, resp, respBody)

	// Write response to client
	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(finalBody)))
	w.Header().Set("X-Request-Id", requestID)
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(finalBody)

	// Record metrics
	duration := time.Since(start)
	status := "2xx"
	if resp.StatusCode >= 400 && resp.StatusCode < 500 {
		status = "4xx"
	} else if resp.StatusCode >= 500 {
		status = "5xx"
	}
	recordRequest(status, duration)
	recordTaskCompleted(p.extractFinalState(finalBody), duration)
}

func (p *a2aProxy) forwardRaw(w http.ResponseWriter, r *http.Request) {
	targetURL := *p.upstream
	targetURL.Path = r.URL.Path
	targetURL.RawQuery = r.URL.RawQuery

	proxyReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL.String(), r.Body)
	if err != nil {
		http.Error(w, "proxy error", http.StatusInternalServerError)
		return
	}
	proxyReq.Header = r.Header.Clone()

	resp, err := p.client.Do(proxyReq)
	if err != nil {
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

func (p *a2aProxy) forwardToUpstream(r *http.Request, body []byte) (*http.Response, []byte, error) {
	targetURL := *p.upstream
	targetURL.Path = r.URL.Path
	targetURL.RawQuery = r.URL.RawQuery

	proxyReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	proxyReq.Header = r.Header.Clone()
	proxyReq.Header.Set("Content-Length", fmt.Sprintf("%d", len(body)))

	resp, err := p.client.Do(proxyReq)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, err
	}

	return resp, respBody, nil
}

func (p *a2aProxy) maybeAutoConfirm(r *http.Request, origBody []byte, resp *http.Response, respBody []byte) []byte {
	// Only process JSON responses
	contentType := resp.Header.Get("Content-Type")
	if !strings.Contains(contentType, "application/json") {
		return respBody
	}

	// Parse the A2A response
	var a2aResp a2aResponse
	if err := json.Unmarshal(respBody, &a2aResp); err != nil {
		return respBody
	}

	// Check if there's a result with input-required state
	if a2aResp.Result == nil {
		return respBody
	}

	var result taskResult
	if err := json.Unmarshal(a2aResp.Result, &result); err != nil {
		return respBody
	}

	if result.Status.State != "input-required" {
		return respBody
	}

	// Check if this is a tool confirmation for an approved tool
	toolName := extractToolConfirmation(result)
	if toolName == "" {
		slog.Info("[A2AProxy] input-required but no tool confirmation detected, passing through",
			"taskId", result.ID, "requestId", r.Header.Get("X-Request-Id"))
		recordAutoConfirm("unknown", "passthrough")
		return respBody
	}

	if !approvedTools[toolName] {
		slog.Warn("[A2AProxy] Tool confirmation requested for NON-APPROVED tool, passing through",
			"taskId", result.ID, "tool", toolName, "requestId", r.Header.Get("X-Request-Id"))
		recordAutoConfirm(toolName, "blocked")
		return respBody
	}

	// Auto-confirm: send confirmation back to upstream
	slog.Info("[A2AProxy] Auto-confirming approved read-only tool",
		"taskId", result.ID, "tool", toolName, "requestId", r.Header.Get("X-Request-Id"))
	recordAutoConfirm(toolName, "confirmed")

	return p.sendConfirmation(r, result.ID, a2aResp.ID)
}

func (p *a2aProxy) sendConfirmation(r *http.Request, taskID string, jsonrpcID interface{}) []byte {
	for attempt := 0; attempt < p.maxConfirmRetries; attempt++ {
		confirmReq := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      jsonrpcID,
			"method":  "tasks/send",
			"params": map[string]interface{}{
				"id": taskID,
				"message": map[string]interface{}{
					"role": "user",
					"parts": []map[string]interface{}{
						{"type": "text", "text": "yes"},
					},
				},
			},
		}

		confirmBody, err := json.Marshal(confirmReq)
		if err != nil {
			slog.Error("[A2AProxy] Failed to marshal confirmation", "error", err)
			break
		}

		targetURL := *p.upstream
		targetURL.Path = r.URL.Path
		targetURL.RawQuery = r.URL.RawQuery

		req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, targetURL.String(), bytes.NewReader(confirmBody))
		if err != nil {
			slog.Error("[A2AProxy] Failed to create confirmation request", "error", err)
			break
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := p.client.Do(req)
		if err != nil {
			slog.Error("[A2AProxy] Confirmation request failed", "error", err, "attempt", attempt+1)
			break
		}

		respBody, err := io.ReadAll(resp.Body)
		resp.Body.Close()
		if err != nil {
			slog.Error("[A2AProxy] Failed to read confirmation response", "error", err)
			break
		}

		// Check if we're done (completed/failed) or need another confirmation
		var a2aResp a2aResponse
		if err := json.Unmarshal(respBody, &a2aResp); err != nil {
			slog.Warn("[A2AProxy] Could not parse confirmation response, returning as-is", "attempt", attempt+1)
			return respBody
		}

		if a2aResp.Result == nil {
			return respBody
		}

		var result taskResult
		if err := json.Unmarshal(a2aResp.Result, &result); err != nil {
			return respBody
		}

		if result.Status.State != "input-required" {
			slog.Info("[A2AProxy] Task completed after auto-confirmation",
				"taskId", taskID, "state", result.Status.State, "attempts", attempt+1)
			return respBody
		}

		// Still input-required — check if it's another approved tool confirmation
		nextTool := extractToolConfirmation(result)
		if nextTool == "" || !approvedTools[nextTool] {
			slog.Warn("[A2AProxy] Subsequent input-required is not an approved tool, stopping auto-confirm",
				"taskId", taskID, "tool", nextTool, "attempt", attempt+1)
			return respBody
		}

		slog.Info("[A2AProxy] Re-confirming approved tool",
			"taskId", taskID, "tool", nextTool, "attempt", attempt+1)
	}

	slog.Error("[A2AProxy] Max confirmation retries reached", "taskId", taskID)
	// Return the last response we got (still input-required)
	return nil
}

// extractToolConfirmation inspects the task result for tool confirmation patterns.
// Returns the tool name if a confirmation is detected, empty string otherwise.
func extractToolConfirmation(result taskResult) string {
	// Check the status message first
	if result.Status.Message != nil {
		if tool := extractToolFromMessage(*result.Status.Message); tool != "" {
			return tool
		}
	}

	// Check history (last agent message)
	for i := len(result.History) - 1; i >= 0; i-- {
		msg := result.History[i]
		if msg.Role == "agent" || msg.Role == "assistant" {
			if tool := extractToolFromMessage(msg); tool != "" {
				return tool
			}
		}
	}

	return ""
}

// extractToolFromMessage looks for tool confirmation patterns in a message.
func extractToolFromMessage(msg message) string {
	for _, p := range msg.Parts {
		text := p.Text

		// Check for explicit tool name in part metadata
		if p.ToolName != "" {
			return p.ToolName
		}
		if p.Name != "" && approvedTools[p.Name] {
			return p.Name
		}

		// Pattern: "adk_request_confirmation" or tool name in confirmation text
		if strings.Contains(text, "adk_request_confirmation") ||
			strings.Contains(text, "confirm") ||
			strings.Contains(text, "Confirm") {
			// Try to find which tool is being confirmed
			for tool := range approvedTools {
				if strings.Contains(text, tool) {
					return tool
				}
			}
			// Generic confirmation without tool name in text —
			// check if any approved tool was recently called in the same history
			// For safety, we only auto-confirm if we can identify the tool
			return ""
		}
	}
	return ""
}

// extractFinalState parses the final response to determine task state for metrics.
func (p *a2aProxy) extractFinalState(body []byte) string {
	if body == nil {
		return "error"
	}
	var resp a2aResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return "unknown"
	}
	if resp.Result == nil {
		return "error"
	}
	var result taskResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return "unknown"
	}
	if result.Status.State == "" {
		return "unknown"
	}
	return result.Status.State
}

