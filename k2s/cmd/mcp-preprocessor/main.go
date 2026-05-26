// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// mcp-preprocessor is an MCP protocol proxy that applies deterministic
// output preprocessing to kubectl tool results before the LLM sees them.
//
// Phase 1: Injects --tail=100 for log retrieval (bounds input)
// Phase 2: Hard truncation with line/token limits, preserves ERROR/WARN lines
//
// Sits between kagent-controller and the actual k2s-tools MCP server.
package main

import (
	"bytes"
	"context"
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
	"sync"
	"time"

	"github.com/google/uuid"
)

const cliName = "mcp-preprocessor"

// Per-tool-call timeout — tool calls to upstream k2s-tools must complete within this.
const upstreamToolCallTimeout = 10 * time.Second

// Per-tool output limits (in lines)
var toolLimits = map[string]toolLimit{
	"k8s_get_resources": {
		MaxLines:  60,
		MaxTokens: 2048,
	},
	"k8s_describe_resource": {
		MaxLines:  120,
		MaxTokens: 4096,
	},
	"k8s_get_pod_logs": {
		MaxLines:       100,
		MaxTokens:      3072,
		PreserveErrors: true,
		HeadLines:      20,
		TailLines:      80,
	},
	"k8s_get_events": {
		MaxLines:  60,
		MaxTokens: 2048,
	},
	"k8s_get_resource_yaml": {
		MaxLines:  150,
		MaxTokens: 4096,
	},
}

// Default limit for any tool not explicitly configured
var defaultLimit = toolLimit{
	MaxLines:  300,
	MaxTokens: 4096,
}

// Default tail lines to inject for log retrieval
const defaultLogTailLines = 100

type toolLimit struct {
	MaxLines       int
	MaxTokens      int
	PreserveErrors bool
	HeadLines      int
	TailLines      int
}

func main() {
	listenAddr := flag.String("addr", ":8084", "preprocessor listen address")
	upstream := flag.String("upstream", "http://k2s-tools.kagent.svc.cluster.local:8084", "upstream MCP tools URL")
	flag.Parse()

	// Structured JSON logging
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	upstreamURL, err := url.Parse(*upstream)
	if err != nil {
		slog.Error("Invalid upstream URL", "url", *upstream, "error", err)
		os.Exit(1)
	}

	pp := &preprocessor{
		upstream: upstreamURL,
		client: &http.Client{
			Timeout: 60 * time.Second,
		},
	}

	// Initialize MCP session with upstream on startup
	go pp.ensureSession()

	// Fallback reverse proxy for non-MCP endpoints
	reverseProxy := httputil.NewSingleHostReverseProxy(upstreamURL)
	reverseProxy.FlushInterval = -1

	mux := http.NewServeMux()
	mux.HandleFunc("/mcp", pp.handleMCP)
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	// Prometheus metrics endpoint
	mux.HandleFunc("/metrics", mcpMetricsHandler)
	// Pass through everything else
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		reverseProxy.ServeHTTP(w, r)
	})

	slog.Info("mcp-preprocessor starting", "component", "mcp-preprocessor", "addr", *listenAddr, "upstream", *upstream)
	if err := http.ListenAndServe(*listenAddr, mux); err != nil {
		slog.Error("Server failed", "error", err)
		os.Exit(1)
	}
}

type preprocessor struct {
	upstream  *url.URL
	client    *http.Client
	sessionMu sync.RWMutex
	sessionID string // MCP session ID for upstream
}

// ensureSession establishes an MCP session with the upstream server.
// Retries with backoff on failure. Called on startup and when session becomes invalid.
func (pp *preprocessor) ensureSession() {
	for {
		err := pp.initializeSession()
		if err == nil {
			pp.sessionMu.RLock()
			sid := pp.sessionID
			pp.sessionMu.RUnlock()
			slog.Info("[MCPPreprocessor] Session established with upstream", "sessionId", sid)
			return
		}
		slog.Warn("[MCPPreprocessor] Failed to initialize upstream session, retrying in 5s", "error", err)
		time.Sleep(5 * time.Second)
	}
}

// initializeSession sends the MCP initialize handshake to upstream and stores the session ID.
func (pp *preprocessor) initializeSession() error {
	initReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "initialize",
		"params": map[string]interface{}{
			"protocolVersion": "2024-11-05",
			"capabilities":    map[string]interface{}{},
			"clientInfo": map[string]interface{}{
				"name":    "mcp-preprocessor",
				"version": "1.0.0",
			},
		},
	}

	body, err := json.Marshal(initReq)
	if err != nil {
		return fmt.Errorf("marshal init request: %w", err)
	}

	targetURL := *pp.upstream
	targetURL.Path = "/mcp"

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create init request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := pp.client.Do(req)
	if err != nil {
		return fmt.Errorf("init request failed: %w", err)
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body) // drain body

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("init returned status %d", resp.StatusCode)
	}

	sessionID := resp.Header.Get("Mcp-Session-Id")
	if sessionID == "" {
		return fmt.Errorf("no Mcp-Session-Id in init response")
	}

	pp.sessionMu.Lock()
	pp.sessionID = sessionID
	pp.sessionMu.Unlock()

	return nil
}

// getSessionID returns the current session ID, or empty if not yet established.
func (pp *preprocessor) getSessionID() string {
	pp.sessionMu.RLock()
	defer pp.sessionMu.RUnlock()
	return pp.sessionID
}

// invalidateAndReconnect marks the current session as invalid and tries to establish a new one.
func (pp *preprocessor) invalidateAndReconnect() {
	pp.sessionMu.Lock()
	pp.sessionID = ""
	pp.sessionMu.Unlock()
	go pp.ensureSession()
}

// MCP JSON-RPC types
type jsonrpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type jsonrpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      interface{}     `json:"id,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   json.RawMessage `json:"error,omitempty"`
}

type toolCallParams struct {
	Name      string                 `json:"name"`
	Arguments map[string]interface{} `json:"arguments,omitempty"`
}

type toolCallResult struct {
	Content []contentPart `json:"content"`
	IsError bool          `json:"isError,omitempty"`
}

type contentPart struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
}

func (pp *preprocessor) handleMCP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()

	// X-Request-Id propagation
	requestID := r.Header.Get("X-Request-Id")
	if requestID == "" {
		requestID = uuid.New().String()
	}
	r.Header.Set("X-Request-Id", requestID)
	w.Header().Set("X-Request-Id", requestID)

	if r.Method != http.MethodPost {
		// Non-POST (SSE init, etc.) — pass through
		pp.forwardRaw(w, r)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	r.Body.Close()

	// Parse JSON-RPC request
	var req jsonrpcRequest
	if err := json.Unmarshal(body, &req); err != nil {
		// Not JSON-RPC — forward as-is
		pp.forwardBody(w, r, body)
		return
	}

	// Only intercept tools/call
	if req.Method != "tools/call" {
		pp.forwardBody(w, r, body)
		return
	}

	// Parse tool call params to get tool name
	var params toolCallParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		pp.forwardBody(w, r, body)
		return
	}

	// Phase 1: Inject tail_lines for log calls
	modifiedBody := body
	if params.Name == "k8s_get_pod_logs" {
		modifiedBody = pp.injectLogTail(body, req, params)
	}

	// Forward to upstream
	resp, respBody, err := pp.forwardToUpstream(r, modifiedBody)
	if err != nil {
		slog.Error("[MCPPreprocessor] Upstream failed", "error", err, "tool", params.Name, "requestId", requestID)
		http.Error(w, "upstream error", http.StatusBadGateway)
		recordMCPRequest(params.Name, "5xx", time.Since(start))
		recordMCPUpstreamError()
		return
	}

	// Phase 2: Preprocess the response
	processedBody := pp.preprocessResponse(respBody, params.Name)

	// Write back
	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(processedBody)))
	w.Header().Set("X-Request-Id", requestID)
	w.Header().Del("Transfer-Encoding")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(processedBody)

	// Record metrics
	status := "2xx"
	if resp.StatusCode >= 400 {
		status = "5xx"
	}
	recordMCPRequest(params.Name, status, time.Since(start))
}

// Phase 1: Inject tail_lines parameter for log retrieval
func (pp *preprocessor) injectLogTail(originalBody []byte, req jsonrpcRequest, params toolCallParams) []byte {
	if params.Arguments == nil {
		params.Arguments = make(map[string]interface{})
	}

	// Only inject if not already set
	if _, exists := params.Arguments["tail_lines"]; !exists {
		if _, exists := params.Arguments["tail"]; !exists {
			params.Arguments["tail_lines"] = defaultLogTailLines
			slog.Info("[MCPPreprocessor] Injected tail_lines for log retrieval",
				"tail_lines", defaultLogTailLines)

			// Rebuild the request
			newParams, err := json.Marshal(params)
			if err != nil {
				return originalBody
			}
			req.Params = newParams
			newBody, err := json.Marshal(req)
			if err != nil {
				return originalBody
			}
			return newBody
		}
	}
	return originalBody
}

// Phase 2: Preprocess tool response — truncate, preserve errors, add markers
func (pp *preprocessor) preprocessResponse(respBody []byte, toolName string) []byte {
	var resp jsonrpcResponse
	if err := json.Unmarshal(respBody, &resp); err != nil {
		return respBody
	}

	// Skip if error response
	if resp.Error != nil {
		return respBody
	}
	if resp.Result == nil {
		return respBody
	}

	var result toolCallResult
	if err := json.Unmarshal(resp.Result, &result); err != nil {
		return respBody
	}

	// Don't preprocess error results from tools
	if result.IsError {
		return respBody
	}

	// Get limits for this tool
	limits := defaultLimit
	if l, ok := toolLimits[toolName]; ok {
		limits = l
	}

	modified := false
	for i, part := range result.Content {
		if part.Type != "text" || part.Text == "" {
			continue
		}

		// Record pre-truncation token count
		preTokens := estimateTokens(part.Text)
		recordOutputTokens(toolName, preTokens)

		processed := truncateOutput(part.Text, limits, toolName)
		if processed != part.Text {
			result.Content[i].Text = processed
			modified = true

			// Determine truncation reason
			lines := strings.Split(part.Text, "\n")
			if len(lines) > limits.MaxLines {
				recordTruncation(toolName, "line_limit")
			} else {
				recordTruncation(toolName, "token_limit")
			}

			slog.Info("[MCPPreprocessor] Output truncated",
				"tool", toolName,
				"originalTokens", preTokens,
				"originalLines", len(lines),
				"component", "mcp-preprocessor")
		}
	}

	if !modified {
		return respBody
	}

	// Re-marshal
	newResult, err := json.Marshal(result)
	if err != nil {
		return respBody
	}
	resp.Result = newResult

	newBody, err := json.Marshal(resp)
	if err != nil {
		return respBody
	}

	slog.Info("[MCPPreprocessor] Preprocessed tool output", "tool", toolName)
	return newBody
}

// truncateOutput applies line and token limits to tool output text.
func truncateOutput(text string, limits toolLimit, toolName string) string {
	lines := strings.Split(text, "\n")
	totalLines := len(lines)

	// If within limits, return as-is
	if totalLines <= limits.MaxLines && estimateTokens(text) <= limits.MaxTokens {
		return text
	}

	// For logs with error preservation
	if limits.PreserveErrors && toolName == "k8s_get_pod_logs" {
		return truncateLogsWithErrorPreservation(lines, limits)
	}

	// Standard truncation: keep first N lines
	return truncateStandard(lines, limits, totalLines)
}

// truncateLogsWithErrorPreservation keeps head + tail + error lines from the middle
func truncateLogsWithErrorPreservation(lines []string, limits toolLimit) string {
	totalLines := len(lines)

	if totalLines <= limits.MaxLines {
		// Within line limit but over token limit — simple line cut
		result := strings.Join(lines, "\n")
		if estimateTokens(result) <= limits.MaxTokens {
			return result
		}
		// Token-based truncation needed
		return truncateByTokens(lines, limits.MaxTokens)
	}

	headCount := limits.HeadLines
	tailCount := limits.TailLines
	if headCount == 0 {
		headCount = 20
	}
	if tailCount == 0 {
		tailCount = 80
	}

	// Ensure we don't exceed total
	if headCount+tailCount >= totalLines {
		return strings.Join(lines, "\n")
	}

	head := lines[:headCount]
	tail := lines[totalLines-tailCount:]
	middleLines := lines[headCount : totalLines-tailCount]

	// Extract error lines from middle
	var errorLines []string
	for _, line := range middleLines {
		if isErrorLine(line) {
			errorLines = append(errorLines, line)
		}
	}

	// Cap preserved error lines to avoid bloat — always keep at least 10
	maxErrorLines := limits.MaxLines - headCount - tailCount - 3 // 3 for markers
	if maxErrorLines < 10 {
		maxErrorLines = 10
	}
	if len(errorLines) > maxErrorLines {
		errorLines = errorLines[len(errorLines)-maxErrorLines:]
	}

	// Build result
	var result []string
	result = append(result, head...)

	omitted := len(middleLines) - len(errorLines)
	if len(errorLines) > 0 {
		result = append(result, fmt.Sprintf("[...%d lines omitted, %d error/warn lines preserved...]", omitted, len(errorLines)))
		result = append(result, errorLines...)
	} else {
		result = append(result, fmt.Sprintf("[...%d lines omitted...]", omitted))
	}

	result = append(result, tail...)

	output := strings.Join(result, "\n")

	// Final token check
	if estimateTokens(output) > limits.MaxTokens {
		return truncateByTokens(result, limits.MaxTokens)
	}

	return output
}

// truncateStandard applies simple head truncation with a footer marker
func truncateStandard(lines []string, limits toolLimit, totalLines int) string {
	maxLines := limits.MaxLines
	if maxLines > totalLines {
		maxLines = totalLines
	}

	kept := lines[:maxLines]
	output := strings.Join(kept, "\n")

	// Check tokens
	if estimateTokens(output) > limits.MaxTokens {
		output = truncateByTokens(kept, limits.MaxTokens)
	}

	// Append truncation notice
	output += fmt.Sprintf("\n[Truncated: showing %d/%d lines]", maxLines, totalLines)

	return output
}

// truncateByTokens cuts lines to stay within token budget
func truncateByTokens(lines []string, maxTokens int) string {
	var result []string
	tokens := 0

	for _, line := range lines {
		lineTokens := estimateTokens(line)
		if tokens+lineTokens > maxTokens-50 { // Reserve 50 tokens for truncation notice
			break
		}
		result = append(result, line)
		tokens += lineTokens
	}

	output := strings.Join(result, "\n")
	output += fmt.Sprintf("\n[Truncated: token limit reached, showing %d/%d lines]", len(result), len(lines))
	return output
}

// isErrorLine checks if a log line contains error/warning indicators
func isErrorLine(line string) bool {
	lower := strings.ToLower(line)
	return strings.Contains(lower, "error") ||
		strings.Contains(lower, "err=") ||
		strings.Contains(lower, "warn") ||
		strings.Contains(lower, "fatal") ||
		strings.Contains(lower, "panic") ||
		strings.Contains(lower, "exception") ||
		strings.Contains(lower, "fail") ||
		strings.Contains(lower, "crashloop") ||
		strings.Contains(lower, "oomkilled") ||
		strings.Contains(lower, "backoff")
}

// estimateTokens provides a rough token count (avg ~4 chars per token for English/code)
func estimateTokens(text string) int {
	return (len(text) + 3) / 4
}

func (pp *preprocessor) forwardRaw(w http.ResponseWriter, r *http.Request) {
	targetURL := *pp.upstream
	targetURL.Path = r.URL.Path
	targetURL.RawQuery = r.URL.RawQuery

	proxyReq, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL.String(), r.Body)
	if err != nil {
		http.Error(w, "proxy error", http.StatusInternalServerError)
		return
	}
	proxyReq.Header = r.Header.Clone()

	// Inject session ID for SSE/GET requests too
	if proxyReq.Header.Get("Mcp-Session-Id") == "" {
		if sid := pp.getSessionID(); sid != "" {
			proxyReq.Header.Set("Mcp-Session-Id", sid)
		}
	}

	resp, err := pp.client.Do(proxyReq)
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

func (pp *preprocessor) forwardBody(w http.ResponseWriter, r *http.Request, body []byte) {
	resp, respBody, err := pp.forwardToUpstream(r, body)
	if err != nil {
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}

	for k, vv := range resp.Header {
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(respBody)))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(respBody)
}

func (pp *preprocessor) forwardToUpstream(r *http.Request, body []byte) (*http.Response, []byte, error) {
	return pp.forwardToUpstreamWithContext(r.Context(), r, body)
}

func (pp *preprocessor) forwardToUpstreamWithContext(ctx context.Context, r *http.Request, body []byte) (*http.Response, []byte, error) {
	targetURL := *pp.upstream
	targetURL.Path = r.URL.Path
	targetURL.RawQuery = r.URL.RawQuery

	proxyReq, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), bytes.NewReader(body))
	if err != nil {
		return nil, nil, err
	}
	proxyReq.Header = r.Header.Clone()
	proxyReq.Header.Set("Content-Length", fmt.Sprintf("%d", len(body)))

	// Inject MCP session ID if we have one and the request doesn't already have one
	if proxyReq.Header.Get("Mcp-Session-Id") == "" {
		if sid := pp.getSessionID(); sid != "" {
			proxyReq.Header.Set("Mcp-Session-Id", sid)
		}
	}

	resp, err := pp.client.Do(proxyReq)
	if err != nil {
		return nil, nil, err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, nil, err
	}

	// Handle session invalidation — if upstream returns 400 with "Invalid session ID",
	// re-establish the session and retry once.
	if resp.StatusCode == http.StatusBadRequest && strings.Contains(string(respBody), "Invalid session ID") {
		slog.Warn("[MCPPreprocessor] Session invalidated by upstream, re-establishing")
		pp.invalidateAndReconnect()

		// Wait briefly for session to be re-established
		for i := 0; i < 10; i++ {
			time.Sleep(500 * time.Millisecond)
			if pp.getSessionID() != "" {
				break
			}
		}

		// Retry with new session
		if sid := pp.getSessionID(); sid != "" {
			retryReq, err := http.NewRequestWithContext(ctx, http.MethodPost, targetURL.String(), bytes.NewReader(body))
			if err != nil {
				return resp, respBody, nil // return original error
			}
			retryReq.Header = r.Header.Clone()
			retryReq.Header.Set("Content-Length", fmt.Sprintf("%d", len(body)))
			retryReq.Header.Set("Mcp-Session-Id", sid)

			retryResp, err := pp.client.Do(retryReq)
			if err != nil {
				return resp, respBody, nil // return original error
			}
			defer retryResp.Body.Close()

			retryBody, err := io.ReadAll(retryResp.Body)
			if err != nil {
				return resp, respBody, nil
			}

			slog.Info("[MCPPreprocessor] Session re-established, retry succeeded", "status", retryResp.StatusCode)
			return retryResp, retryBody, nil
		}
	}

	return resp, respBody, nil
}

// buildTimeoutResponse constructs a structured JSON-RPC response for tool call timeouts.
// The response is a valid tool result with isError=true, containing operator-friendly details.
func buildTimeoutResponse(id interface{}, toolName string, elapsed time.Duration, requestID string) []byte {
	timeoutMsg := fmt.Sprintf(
		"Tool call timeout: %s did not respond within %s (elapsed: %s).\n"+
			"Impact: This data source is unavailable for this request.\n"+
			"Reason: tool_timeout\n"+
			"RequestId: %s\n"+
			"Available deterministic workflows: health, errors, nodes, pods, logs, deploy, diagnose, status",
		toolName, upstreamToolCallTimeout, elapsed.Round(time.Millisecond), requestID,
	)

	result := map[string]interface{}{
		"content": []map[string]interface{}{
			{"type": "text", "text": timeoutMsg},
		},
		"isError": true,
	}
	resultBytes, _ := json.Marshal(result)

	resp := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  json.RawMessage(resultBytes),
	}
	body, _ := json.Marshal(resp)
	return body
}
