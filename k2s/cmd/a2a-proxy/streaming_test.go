// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// parseSSEEvents extracts SSE events from a recorded response body.
// Returns a slice of (eventType, jsonData) pairs.
func parseSSEEvents(body string) []sseEvent {
	var events []sseEvent
	scanner := bufio.NewScanner(strings.NewReader(body))
	var currentEvent string
	var currentData string

	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "event: ") {
			currentEvent = strings.TrimPrefix(line, "event: ")
		} else if strings.HasPrefix(line, "data: ") {
			currentData = strings.TrimPrefix(line, "data: ")
		} else if line == "" && currentEvent != "" {
			events = append(events, sseEvent{Type: currentEvent, Data: currentData})
			currentEvent = ""
			currentData = ""
		}
	}
	// Handle case where there's no trailing blank line
	if currentEvent != "" {
		events = append(events, sseEvent{Type: currentEvent, Data: currentData})
	}
	return events
}

type sseEvent struct {
	Type string
	Data string
}

func TestStreamingAGUI_ShortcutPath_EventSequence(t *testing.T) {
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

	mcpURL, _ := url.Parse(mockMCP.URL)
	upstreamURL, _ := url.Parse("http://localhost:9999") // not used for shortcuts

	scRouter := &shortcutRouter{
		mcpUpstream: mcpURL,
		client:      mockMCP.Client(),
	}

	handler := &aguiCompatHandler{
		upstream:    upstreamURL,
		mcpUpstream: mcpURL,
		proxy:       &a2aProxy{upstream: upstreamURL, maxConfirmRetries: 3, client: &http.Client{}},
		scRouter:    scRouter,
		client:      mockMCP.Client(),
	}

	body := `{"thread_id":"t1","run_id":"r1","messages":[{"id":"m1","role":"user","content":"nodes"}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/agui/chat", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	handler.handleAGUI(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}

	// Verify SSE content type
	ct := w.Header().Get("Content-Type")
	if !strings.Contains(ct, "text/event-stream") {
		t.Errorf("expected text/event-stream content type, got %q", ct)
	}

	events := parseSSEEvents(w.Body.String())

	// Verify event sequence: RUN_STARTED → TEXT_MESSAGE_START → TEXT_MESSAGE_CONTENT(s) → TEXT_MESSAGE_END → RUN_FINISHED
	if len(events) < 5 {
		t.Fatalf("expected at least 5 SSE events, got %d", len(events))
	}

	// First event must be RUN_STARTED
	if events[0].Type != aguiEventRunStarted {
		t.Errorf("event[0]: expected %s, got %s", aguiEventRunStarted, events[0].Type)
	}

	// Second event must be TEXT_MESSAGE_START
	if events[1].Type != aguiEventTextMessageStart {
		t.Errorf("event[1]: expected %s, got %s", aguiEventTextMessageStart, events[1].Type)
	}

	// Third event must be thinking indicator (first TEXT_MESSAGE_CONTENT)
	if events[2].Type != aguiEventTextMessageContent {
		t.Errorf("event[2]: expected %s, got %s", aguiEventTextMessageContent, events[2].Type)
	}
	var thinkingContent map[string]interface{}
	json.Unmarshal([]byte(events[2].Data), &thinkingContent)
	delta, _ := thinkingContent["delta"].(string)
	if !strings.Contains(delta, "Thinking") {
		t.Errorf("event[2]: expected thinking indicator, got delta=%q", delta)
	}

	// Last two events must be TEXT_MESSAGE_END and RUN_FINISHED
	lastIdx := len(events) - 1
	if events[lastIdx].Type != aguiEventRunFinished {
		t.Errorf("event[%d]: expected %s, got %s", lastIdx, aguiEventRunFinished, events[lastIdx].Type)
	}
	if events[lastIdx-1].Type != aguiEventTextMessageEnd {
		t.Errorf("event[%d]: expected %s, got %s", lastIdx-1, aguiEventTextMessageEnd, events[lastIdx-1].Type)
	}

	// Content events between thinking and END should contain the actual response
	var responseParts []string
	for i := 3; i < lastIdx-1; i++ {
		if events[i].Type != aguiEventTextMessageContent {
			t.Errorf("event[%d]: expected %s in content section, got %s", i, aguiEventTextMessageContent, events[i].Type)
		}
		var contentEvent map[string]interface{}
		json.Unmarshal([]byte(events[i].Data), &contentEvent)
		d, _ := contentEvent["delta"].(string)
		responseParts = append(responseParts, d)
	}
	fullResponse := strings.Join(responseParts, "")
	if !strings.Contains(fullResponse, "nodes Ready") {
		t.Errorf("response should contain node data, got %q", fullResponse)
	}
}

func TestStreamingAGUI_ThinkingIndicator_IsFirstContent(t *testing.T) {
	// Even for shortcut queries, the thinking indicator should be the first content event
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

	mcpURL, _ := url.Parse(mockMCP.URL)
	upstreamURL, _ := url.Parse("http://localhost:9999")

	handler := &aguiCompatHandler{
		upstream:    upstreamURL,
		mcpUpstream: mcpURL,
		proxy:       &a2aProxy{upstream: upstreamURL, maxConfirmRetries: 3, client: &http.Client{}},
		scRouter:    &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()},
		client:      mockMCP.Client(),
	}

	body := `{"thread_id":"t1","run_id":"r1","messages":[{"id":"m1","role":"user","content":"help"}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/agui/chat", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	handler.handleAGUI(w, req)

	events := parseSSEEvents(w.Body.String())

	// Find first TEXT_MESSAGE_CONTENT
	for _, evt := range events {
		if evt.Type == aguiEventTextMessageContent {
			var content map[string]interface{}
			json.Unmarshal([]byte(evt.Data), &content)
			delta, _ := content["delta"].(string)
			if !strings.Contains(delta, "Thinking") {
				t.Errorf("first content event should be thinking indicator, got %q", delta)
			}
			return
		}
	}
	t.Error("no TEXT_MESSAGE_CONTENT event found")
}

func TestStreamResponseChunked_ShortResponse(t *testing.T) {
	w := httptest.NewRecorder()
	flusher := w // httptest.ResponseRecorder implements Flusher

	streamResponseChunked(w, flusher, "msg-1", "short response")

	events := parseSSEEvents(w.Body.String())
	if len(events) != 1 {
		t.Errorf("short response should produce 1 event, got %d", len(events))
	}
	if events[0].Type != aguiEventTextMessageContent {
		t.Errorf("expected TEXT_MESSAGE_CONTENT, got %s", events[0].Type)
	}
}

func TestStreamResponseChunked_LongResponse(t *testing.T) {
	w := httptest.NewRecorder()
	flusher := w

	// Generate a response with 20 lines (should produce multiple chunks)
	var lines []string
	for i := 0; i < 20; i++ {
		lines = append(lines, "line content here")
	}
	longResponse := strings.Join(lines, "\n")

	streamResponseChunked(w, flusher, "msg-1", longResponse)

	events := parseSSEEvents(w.Body.String())
	// 20 lines / 5 per chunk = 4 events
	if len(events) != 4 {
		t.Errorf("expected 4 chunked events for 20 lines, got %d", len(events))
	}
	for _, evt := range events {
		if evt.Type != aguiEventTextMessageContent {
			t.Errorf("all events should be TEXT_MESSAGE_CONTENT, got %s", evt.Type)
		}
	}

	// Verify all content is preserved when chunks are reassembled
	var reassembled []string
	for _, evt := range events {
		var content map[string]interface{}
		json.Unmarshal([]byte(evt.Data), &content)
		d, _ := content["delta"].(string)
		reassembled = append(reassembled, d)
	}
	full := strings.Join(reassembled, "")
	if full != longResponse {
		t.Errorf("reassembled content should match original\nGot:  %q\nWant: %q", full, longResponse)
	}
}

func TestStreamResponseChunked_EmptyResponse(t *testing.T) {
	w := httptest.NewRecorder()
	flusher := w

	streamResponseChunked(w, flusher, "msg-1", "")

	if w.Body.Len() != 0 {
		t.Errorf("empty response should produce no SSE events, got %d bytes", w.Body.Len())
	}
}

func TestStreamResponseChunked_ExactChunkBoundary(t *testing.T) {
	w := httptest.NewRecorder()
	flusher := w

	// Exactly streamingChunkLines lines should produce 1 event (short path)
	var lines []string
	for i := 0; i < streamingChunkLines; i++ {
		lines = append(lines, "line")
	}
	response := strings.Join(lines, "\n")

	streamResponseChunked(w, flusher, "msg-1", response)

	events := parseSSEEvents(w.Body.String())
	if len(events) != 1 {
		t.Errorf("exactly %d lines should produce 1 event, got %d", streamingChunkLines, len(events))
	}
}

func TestStreamResponseChunked_ChunkBoundaryPlusOne(t *testing.T) {
	w := httptest.NewRecorder()
	flusher := w

	// streamingChunkLines + 1 lines → 2 chunks
	var lines []string
	for i := 0; i < streamingChunkLines+1; i++ {
		lines = append(lines, "line")
	}
	response := strings.Join(lines, "\n")

	streamResponseChunked(w, flusher, "msg-1", response)

	events := parseSSEEvents(w.Body.String())
	if len(events) != 2 {
		t.Errorf("expected 2 chunks for %d lines, got %d", streamingChunkLines+1, len(events))
	}
}

func TestStreamingAGUI_LLMFallback_EmitsThinking(t *testing.T) {
	// Simulate LLM path: no shortcut match, kagent returns a response
	mockKagent := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resp := map[string]interface{}{
			"jsonrpc": "2.0",
			"id":      1,
			"result": map[string]interface{}{
				"id": "task-123",
				"status": map[string]interface{}{
					"state": "completed",
					"message": map[string]interface{}{
						"role": "agent",
						"parts": []map[string]interface{}{
							{"type": "text", "text": "The cluster has 2 nodes, both in Ready state.\nNode kubemaster runs as control-plane.\nNode worker1 runs workloads."},
						},
					},
				},
			},
		}
		json.NewEncoder(w).Encode(resp)
	}))
	defer mockKagent.Close()

	kagentURL, _ := url.Parse(mockKagent.URL)
	mcpURL, _ := url.Parse("http://localhost:9998") // shortcuts will fail, forcing LLM path

	handler := &aguiCompatHandler{
		upstream:    kagentURL,
		mcpUpstream: mcpURL,
		proxy:       &a2aProxy{upstream: kagentURL, maxConfirmRetries: 3, client: mockKagent.Client()},
		scRouter:    &shortcutRouter{mcpUpstream: mcpURL, client: &http.Client{}},
		client:      mockKagent.Client(),
	}

	body := `{"thread_id":"t1","run_id":"r1","messages":[{"id":"m1","role":"user","content":"describe the cluster topology"}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/agui/chat", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	handler.handleAGUI(w, req)

	events := parseSSEEvents(w.Body.String())

	// Verify thinking indicator appears
	foundThinking := false
	for _, evt := range events {
		if evt.Type == aguiEventTextMessageContent {
			var content map[string]interface{}
			json.Unmarshal([]byte(evt.Data), &content)
			d, _ := content["delta"].(string)
			if strings.Contains(d, "Thinking") {
				foundThinking = true
				break
			}
		}
	}
	if !foundThinking {
		t.Error("expected thinking indicator in SSE events for LLM path")
	}

	// Verify actual response content appears
	var allContent strings.Builder
	for _, evt := range events {
		if evt.Type == aguiEventTextMessageContent {
			var content map[string]interface{}
			json.Unmarshal([]byte(evt.Data), &content)
			d, _ := content["delta"].(string)
			allContent.WriteString(d)
		}
	}
	if !strings.Contains(allContent.String(), "2 nodes") {
		t.Errorf("expected response content in events, got %q", allContent.String())
	}
}

func TestStreamingAGUI_ErrorResponse_StillStreams(t *testing.T) {
	// Simulate kagent being unreachable — error should still stream
	unreachableURL, _ := url.Parse("http://localhost:1") // will fail to connect
	mcpURL, _ := url.Parse("http://localhost:2")

	handler := &aguiCompatHandler{
		upstream:    unreachableURL,
		mcpUpstream: mcpURL,
		proxy:       &a2aProxy{upstream: unreachableURL, maxConfirmRetries: 3, client: &http.Client{}},
		scRouter:    &shortcutRouter{mcpUpstream: mcpURL, client: &http.Client{}},
		client:      &http.Client{},
	}

	body := `{"thread_id":"t1","run_id":"r1","messages":[{"id":"m1","role":"user","content":"what happened to my cluster"}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/agui/chat", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	handler.handleAGUI(w, req)

	events := parseSSEEvents(w.Body.String())

	// Should still have full event sequence even for errors
	foundStart := false
	foundContent := false
	foundEnd := false
	for _, evt := range events {
		switch evt.Type {
		case aguiEventRunStarted:
			foundStart = true
		case aguiEventTextMessageContent:
			foundContent = true
		case aguiEventRunFinished:
			foundEnd = true
		}
	}
	if !foundStart || !foundContent || !foundEnd {
		t.Errorf("error response should have complete event sequence: start=%v content=%v end=%v",
			foundStart, foundContent, foundEnd)
	}
}

func TestStreamingAGUI_XAccelBuffering(t *testing.T) {
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

	mcpURL, _ := url.Parse(mockMCP.URL)
	upstreamURL, _ := url.Parse("http://localhost:9999")

	handler := &aguiCompatHandler{
		upstream:    upstreamURL,
		mcpUpstream: mcpURL,
		proxy:       &a2aProxy{upstream: upstreamURL, maxConfirmRetries: 3, client: &http.Client{}},
		scRouter:    &shortcutRouter{mcpUpstream: mcpURL, client: mockMCP.Client()},
		client:      mockMCP.Client(),
	}

	body := `{"thread_id":"t1","run_id":"r1","messages":[{"id":"m1","role":"user","content":"help"}]}`
	req := httptest.NewRequest(http.MethodPost, "/api/agui/chat", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	handler.handleAGUI(w, req)

	// Verify streaming headers
	if w.Header().Get("X-Accel-Buffering") != "no" {
		t.Error("X-Accel-Buffering should be 'no' for nginx streaming")
	}
	if w.Header().Get("Cache-Control") != "no-cache" {
		t.Error("Cache-Control should be 'no-cache'")
	}
}

