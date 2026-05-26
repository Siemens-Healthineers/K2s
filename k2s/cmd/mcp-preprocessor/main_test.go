// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func TestEstimateTokens(t *testing.T) {
	if estimateTokens("") != 0 {
		t.Error("empty string should be 0 tokens")
	}
	if estimateTokens("hello") != 2 {
		t.Errorf("got %d", estimateTokens("hello"))
	}
	if estimateTokens(strings.Repeat("x", 4000)) != 1000 {
		t.Errorf("got %d", estimateTokens(strings.Repeat("x", 4000)))
	}
}

func TestIsErrorLine(t *testing.T) {
	errors := []string{
		"ERROR: connection refused",
		"level=error msg=failed",
		"WARN: deprecated API",
		"panic: runtime error",
		"FATAL: cannot start",
		"err=context deadline exceeded",
		"Back-off restarting failed container (CrashLoopBackOff)",
	}
	normals := []string{
		"INFO: server started",
		"GET /healthz 200 OK",
		"debug: processing request",
	}
	for _, l := range errors {
		if !isErrorLine(l) {
			t.Errorf("expected isErrorLine(%q) = true", l)
		}
	}
	for _, l := range normals {
		if isErrorLine(l) {
			t.Errorf("expected isErrorLine(%q) = false", l)
		}
	}
}

func TestTruncateOutput_SmallOutput(t *testing.T) {
	text := "NAME READY STATUS\npod-1 1/1 Running\npod-2 1/1 Running"
	limits := toolLimit{MaxLines: 60, MaxTokens: 2048}
	result := truncateOutput(text, limits, "k8s_get_resources")
	if result != text {
		t.Error("small output should not be modified")
	}
}

func TestTruncateOutput_LargeOutput(t *testing.T) {
	var lines []string
	for i := 0; i < 100; i++ {
		lines = append(lines, fmt.Sprintf("pod-%03d 1/1 Running 0 %dd", i, i))
	}
	text := strings.Join(lines, "\n")
	limits := toolLimit{MaxLines: 60, MaxTokens: 2048}
	result := truncateOutput(text, limits, "k8s_get_resources")
	if !strings.Contains(result, "[Truncated:") {
		t.Error("expected truncation notice")
	}
	if !strings.Contains(result, "60/100") {
		t.Errorf("expected 60/100 in notice")
	}
}

func TestTruncateLogsWithErrorPreservation(t *testing.T) {
	var lines []string
	for i := 0; i < 200; i++ {
		if i == 50 {
			lines = append(lines, "ERROR: database connection failed")
		} else if i == 100 {
			lines = append(lines, "WARN: high memory usage")
		} else {
			lines = append(lines, fmt.Sprintf("INFO: request %d", i))
		}
	}
	limits := toolLimit{MaxLines: 100, MaxTokens: 3072, PreserveErrors: true, HeadLines: 20, TailLines: 80}
	result := truncateLogsWithErrorPreservation(lines, limits)
	if !strings.Contains(result, "ERROR: database connection failed") {
		t.Error("ERROR line should be preserved")
	}
	if !strings.Contains(result, "WARN: high memory usage") {
		t.Error("WARN line should be preserved")
	}
	if !strings.Contains(result, "lines omitted") {
		t.Error("expected omission marker")
	}
}

func TestInjectLogTail(t *testing.T) {
	pp := &preprocessor{}
	params := toolCallParams{
		Name:      "k8s_get_pod_logs",
		Arguments: map[string]interface{}{"pod_name": "nginx", "namespace": "default"},
	}
	paramsJSON, _ := json.Marshal(params)
	req := jsonrpcRequest{JSONRPC: "2.0", ID: 1, Method: "tools/call", Params: paramsJSON}
	originalBody, _ := json.Marshal(req)
	result := pp.injectLogTail(originalBody, req, params)
	var modReq jsonrpcRequest
	json.Unmarshal(result, &modReq)
	var modParams toolCallParams
	json.Unmarshal(modReq.Params, &modParams)
	if modParams.Arguments["tail_lines"] != float64(100) {
		t.Errorf("expected tail_lines=100, got %v", modParams.Arguments["tail_lines"])
	}
}

func TestInjectLogTail_AlreadySet(t *testing.T) {
	pp := &preprocessor{}
	params := toolCallParams{
		Name:      "k8s_get_pod_logs",
		Arguments: map[string]interface{}{"pod_name": "nginx", "tail_lines": float64(50)},
	}
	paramsJSON, _ := json.Marshal(params)
	req := jsonrpcRequest{JSONRPC: "2.0", ID: 1, Method: "tools/call", Params: paramsJSON}
	originalBody, _ := json.Marshal(req)
	result := pp.injectLogTail(originalBody, req, params)
	if string(result) != string(originalBody) {
		t.Error("should not override existing tail_lines")
	}
}

func TestPreprocessResponse_ErrorResultPassthrough(t *testing.T) {
	pp := &preprocessor{}
	result := toolCallResult{
		Content: []contentPart{{Type: "text", Text: strings.Repeat("x\n", 500)}},
		IsError: true,
	}
	resultJSON, _ := json.Marshal(result)
	resp := jsonrpcResponse{JSONRPC: "2.0", ID: 1, Result: resultJSON}
	respBody, _ := json.Marshal(resp)
	processed := pp.preprocessResponse(respBody, "k8s_get_resources")
	if string(processed) != string(respBody) {
		t.Error("error results should pass through unchanged")
	}
}

func TestTruncateByTokens(t *testing.T) {
	var lines []string
	for i := 0; i < 100; i++ {
		lines = append(lines, strings.Repeat("x", 40))
	}
	result := truncateByTokens(lines, 200)
	if !strings.Contains(result, "[Truncated: token limit reached") {
		t.Error("expected token truncation notice")
	}
}

func TestBuildTimeoutResponse(t *testing.T) {
	result := buildTimeoutResponse(42, "k8s_get_pod_logs", 10*1e9, "req-123")
	if result == nil {
		t.Fatal("expected non-nil result")
	}

	var resp struct {
		JSONRPC string `json:"jsonrpc"`
		ID      interface{}
		Result  struct {
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			IsError bool `json:"isError"`
		} `json:"result"`
	}
	if err := json.Unmarshal(result, &resp); err != nil {
		t.Fatalf("failed to parse timeout response: %v", err)
	}
	if resp.JSONRPC != "2.0" {
		t.Errorf("expected jsonrpc '2.0', got '%s'", resp.JSONRPC)
	}
	if !resp.Result.IsError {
		t.Error("expected isError=true")
	}
	if len(resp.Result.Content) == 0 {
		t.Fatal("expected content")
	}
	text := resp.Result.Content[0].Text
	if !strings.Contains(text, "tool_timeout") {
		t.Errorf("expected 'tool_timeout' in text, got: %s", text)
	}
	if !strings.Contains(text, "k8s_get_pod_logs") {
		t.Errorf("expected tool name in text, got: %s", text)
	}
	if !strings.Contains(text, "req-123") {
		t.Errorf("expected requestId in text, got: %s", text)
	}
	if !strings.Contains(text, "Available deterministic workflows") {
		t.Errorf("expected available workflows in text, got: %s", text)
	}
}

func TestUpstreamToolCallTimeout_Value(t *testing.T) {
	if upstreamToolCallTimeout != 10*1e9 {
		t.Errorf("expected 10s, got %v", upstreamToolCallTimeout)
	}
}
