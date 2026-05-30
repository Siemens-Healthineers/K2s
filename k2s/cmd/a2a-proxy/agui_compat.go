// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// AG-UI compatibility layer — translates AG-UI protocol requests
// (POST /api/agui/chat) into A2A protocol calls to kagent-controller.
//
// This shim allows AG-UI clients to work transparently with the kagent backend by:
//   1. Receiving AG-UI RunAgentInput JSON
//   2. Trying /api/shortcuts first (deterministic fast-path)
//   3. Falling back to A2A tasks/send to kagent-controller
//   4. Converting A2A responses back to AG-UI SSE format
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
)

// aguiCompatHandler bridges the old AG-UI protocol to the new A2A/shortcut backend.
type aguiCompatHandler struct {
	upstream    *url.URL // kagent-controller
	mcpUpstream *url.URL // mcp-preprocessor for shortcuts
	proxy       *a2aProxy
	scRouter    *shortcutRouter
	client      *http.Client
}

// aguiRunAgentInput represents the legacy AG-UI request payload from the Headlamp plugin.
type aguiRunAgentInput struct {
	ThreadID string        `json:"thread_id"`
	RunID    string        `json:"run_id"`
	Messages []aguiMessage `json:"messages"`
	Context  []aguiContext `json:"context,omitempty"`
}

type aguiMessage struct {
	ID      string `json:"id"`
	Role    string `json:"role"`
	Content string `json:"content"`
}

type aguiContext struct {
	Type    string `json:"type"`
	Content string `json:"content"`
}

// AG-UI SSE event types
const (
	aguiEventRunStarted        = "RUN_STARTED"
	aguiEventTextMessageStart  = "TEXT_MESSAGE_START"
	aguiEventTextMessageContent = "TEXT_MESSAGE_CONTENT"
	aguiEventTextMessageEnd    = "TEXT_MESSAGE_END"
	aguiEventRunFinished       = "RUN_FINISHED"
)

// streamingChunkLines controls the approximate line-grouping size for incremental
// SSE delivery. Each chunk emits a TEXT_MESSAGE_CONTENT event and flushes.
// Smaller values = smoother streaming but more SSE events.
const streamingChunkLines = 5

// handleAGUI handles POST /api/agui/chat from the legacy Headlamp plugin.
// Flow: try shortcut first (fast, deterministic), fall back to kagent A2A.
//
// Streaming behavior:
//   - RUN_STARTED + TEXT_MESSAGE_START emitted immediately (<50ms)
//   - A "thinking" indicator is flushed before backend execution begins
//   - Response is delivered incrementally in line-grouped chunks
//   - Each chunk is a TEXT_MESSAGE_CONTENT SSE event, flushed immediately
//   - This reduces perceived latency (time-to-first-token) from 4-7s to <100ms
func (h *aguiCompatHandler) handleAGUI(w http.ResponseWriter, r *http.Request) {
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

	// Parse AG-UI RunAgentInput
	var input aguiRunAgentInput
	if err := json.Unmarshal(body, &input); err != nil {
		slog.Error("[AG-UI Compat] Failed to parse RunAgentInput", "error", err)
		http.Error(w, "invalid JSON", http.StatusBadRequest)
		return
	}

	// Extract the last user message as the query
	query := extractLastUserMessage(input)
	if query == "" {
		http.Error(w, `{"error":"no user message found"}`, http.StatusBadRequest)
		return
	}

	slog.Info("[AG-UI Compat] Received AG-UI request", "query", query, "threadId", input.ThreadID)

	// Set up SSE response headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming not supported", http.StatusInternalServerError)
		return
	}

	runID := input.RunID
	if runID == "" {
		runID = uuid.New().String()
	}
	messageID := uuid.New().String()

	// --- Streaming phase 1: emit start events + thinking indicator immediately ---
	// This ensures the user sees output within ~50ms instead of waiting 4-7s.
	writeSSEEvent(w, flusher, aguiEventRunStarted, map[string]interface{}{
		"type":      aguiEventRunStarted,
		"thread_id": input.ThreadID,
		"run_id":    runID,
	})
	writeSSEEvent(w, flusher, aguiEventTextMessageStart, map[string]interface{}{
		"type":       aguiEventTextMessageStart,
		"message_id": messageID,
		"role":       "assistant",
	})

	// Emit thinking indicator — first visible token for the user
	writeSSEEvent(w, flusher, aguiEventTextMessageContent, map[string]interface{}{
		"type":       aguiEventTextMessageContent,
		"message_id": messageID,
		"delta":      "⏳ Thinking...\n\n",
	})
	ttft := time.Since(start)
	recordTTFT(ttft)

	// --- Streaming phase 2: execute backend (shortcut or LLM) ---
	responseText := h.tryShortcutPath(query)
	source := "shortcut"
	if responseText == "" {
		source = "llm"
		responseText = h.routeToKagent(r, query, input)
	}

	// --- Streaming phase 3: deliver response incrementally ---
	streamResponseChunked(w, flusher, messageID, responseText)

	// --- Streaming phase 4: finalize ---
	writeSSEEvent(w, flusher, aguiEventTextMessageEnd, map[string]interface{}{
		"type":       aguiEventTextMessageEnd,
		"message_id": messageID,
	})
	writeSSEEvent(w, flusher, aguiEventRunFinished, map[string]interface{}{
		"type":      aguiEventRunFinished,
		"thread_id": input.ThreadID,
		"run_id":    runID,
	})

	elapsed := time.Since(start)
	slog.Info("[AG-UI Compat] AG-UI request completed",
		"query", query, "elapsed", elapsed.String(), "ttft", ttft.String(),
		"source", source, "responseLen", len(responseText), "streamed", true)
	recordStreamingCompletion(source, elapsed, ttft)
}

// tryShortcutPath attempts to match the query against shortcuts.
// Returns the formatted response text or empty string if no match.
func (h *aguiCompatHandler) tryShortcutPath(query string) string {
	lower := strings.TrimSpace(strings.ToLower(query))

	// Apply phrase aliases — rewrite natural-language phrases to canonical shortcut form
	rewritten, alias := rewriteQuery(lower)
	if alias != "" {
		slog.Info("[AG-UI Compat] Phrase alias matched", "original", lower, "rewritten", rewritten, "alias", alias)
		lower = rewritten
		query = rewritten // pass canonical form to handler
		recordPhraseAlias(alias)
	}

	for _, sc := range shortcuts {
		if strings.HasPrefix(lower, sc.Pattern) || lower == strings.TrimSpace(sc.Pattern) {
			resp, err := sc.Handler(h.scRouter, query)
			if err != nil {
				slog.Warn("[AG-UI Compat] Shortcut handler failed, falling through to LLM",
					"pattern", sc.Pattern, "error", err)
				return ""
			}
			slog.Info("[AG-UI Compat] Shortcut matched", "pattern", sc.Pattern, "query", query)
			return formatShortcutAsText(resp)
		}
	}
	return ""
}

// routeToKagent sends the query to the kagent-controller via A2A protocol
// and converts the response to a plain text string.
func (h *aguiCompatHandler) routeToKagent(r *http.Request, query string, input aguiRunAgentInput) string {
	// Determine agent name from path or default
	agentName := extractAgentNameFromPath(r.URL.Path)

	// Build A2A tasks/send request
	a2aReq := map[string]interface{}{
		"jsonrpc": "2.0",
		"id":      1,
		"method":  "tasks/send",
		"params": map[string]interface{}{
			"id": uuid.New().String(),
			"message": map[string]interface{}{
				"role": "user",
				"parts": []map[string]interface{}{
					{"type": "text", "text": query},
				},
			},
		},
	}

	reqBody, err := json.Marshal(a2aReq)
	if err != nil {
		slog.Error("[AG-UI Compat] Failed to marshal A2A request", "error", err)
		return "Error: failed to create request to AI agent"
	}

	// Forward to a2a-proxy's own A2A handler (includes auto-confirmation logic)
	targetURL := *h.upstream
	targetURL.Path = fmt.Sprintf("/api/a2a/kagent/%s", agentName)

	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost, targetURL.String(), bytes.NewReader(reqBody))
	if err != nil {
		slog.Error("[AG-UI Compat] Failed to create A2A request", "error", err)
		return "Error: failed to connect to AI agent"
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Request-Id", r.Header.Get("X-Request-Id"))

	resp, err := h.client.Do(req)
	if err != nil {
		slog.Error("[AG-UI Compat] A2A request failed", "error", err)
		return fmt.Sprintf("Error: AI agent unreachable (%s). Try deterministic shortcuts: health, nodes, pods, errors", err.Error())
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		slog.Error("[AG-UI Compat] Failed to read A2A response", "error", err)
		return "Error: failed to read AI agent response"
	}

	if resp.StatusCode != http.StatusOK {
		slog.Warn("[AG-UI Compat] A2A returned non-200", "status", resp.StatusCode, "body", string(respBody))
		return fmt.Sprintf("Error: AI agent returned HTTP %d. Try: health, nodes, pods, errors", resp.StatusCode)
	}

	// Parse A2A response and extract text
	return extractTextFromA2AResponse(respBody)
}

// extractLastUserMessage finds the last user message in AG-UI input.
func extractLastUserMessage(input aguiRunAgentInput) string {
	for i := len(input.Messages) - 1; i >= 0; i-- {
		if input.Messages[i].Role == "user" && input.Messages[i].Content != "" {
			return input.Messages[i].Content
		}
	}
	return ""
}

// extractAgentNameFromPath extracts agent name from the URL path.
// Supports both /api/agui/chat (uses default agent) and /api/a2a/kagent/<name> format.
func extractAgentNameFromPath(path string) string {
	// Check if path contains an explicit agent name
	if strings.Contains(path, "/api/a2a/kagent/") {
		parts := strings.Split(path, "/api/a2a/kagent/")
		if len(parts) > 1 && parts[1] != "" {
			return strings.Split(parts[1], "/")[0]
		}
	}
	// Default agent names to try (copilot-cli first, then k2s-assistant for ollama)
	return "copilot-cli"
}

// extractTextFromA2AResponse parses an A2A JSON-RPC response and extracts all text parts.
func extractTextFromA2AResponse(body []byte) string {
	var resp struct {
		Result struct {
			ID      string `json:"id"`
			Status  struct {
				State   string `json:"state"`
				Message *struct {
					Role  string `json:"role"`
					Parts []struct {
						Type string `json:"type"`
						Text string `json:"text"`
					} `json:"parts"`
				} `json:"message"`
			} `json:"status"`
			History []struct {
				Role  string `json:"role"`
				Parts []struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"parts"`
			} `json:"history"`
		} `json:"result"`
		Error json.RawMessage `json:"error"`
	}

	if err := json.Unmarshal(body, &resp); err != nil {
		return string(body)
	}

	if resp.Error != nil {
		return fmt.Sprintf("Error from AI agent: %s", string(resp.Error))
	}

	// Collect text from status message
	var texts []string
	if resp.Result.Status.Message != nil {
		for _, p := range resp.Result.Status.Message.Parts {
			if p.Type == "text" && p.Text != "" {
				texts = append(texts, p.Text)
			}
		}
	}

	// Also collect from history (last agent message)
	for i := len(resp.Result.History) - 1; i >= 0; i-- {
		msg := resp.Result.History[i]
		if msg.Role == "agent" || msg.Role == "assistant" {
			for _, p := range msg.Parts {
				if p.Type == "text" && p.Text != "" {
					texts = append(texts, p.Text)
				}
			}
			break
		}
	}

	if len(texts) == 0 {
		if resp.Result.Status.State == "input-required" {
			return "The AI agent needs additional input to complete this request. Please try a more specific query or use a shortcut: health, nodes, pods, errors"
		}
		return "No response from AI agent. Try: health, nodes, pods, errors, diagnose <pod>"
	}

	return strings.Join(texts, "\n")
}

// formatShortcutAsText converts a shortcutResponse into plain text for AG-UI.
func formatShortcutAsText(resp *shortcutResponse) string {
	var parts []string
	if resp.Status != "" {
		parts = append(parts, resp.Status)
	}
	if resp.Details != "" {
		parts = append(parts, "")
		parts = append(parts, resp.Details)
	}
	if len(resp.Followups) > 0 {
		parts = append(parts, "")
		parts = append(parts, "Follow-up queries: "+strings.Join(resp.Followups, ", "))
	}
	return strings.Join(parts, "\n")
}

// streamResponseChunked splits responseText into line-grouped chunks and emits
// each as a separate TEXT_MESSAGE_CONTENT SSE event, flushed immediately.
// This creates an incremental rendering effect in the client UI.
//
// Chunking strategy: group lines into batches of streamingChunkLines.
// Each chunk is emitted as a delta and flushed, so the client renders
// progressively rather than waiting for the full response.
func streamResponseChunked(w http.ResponseWriter, flusher http.Flusher, messageID string, responseText string) {
	if responseText == "" {
		return
	}

	lines := strings.Split(responseText, "\n")
	totalLines := len(lines)

	// For short responses (≤ streamingChunkLines), emit as a single chunk
	if totalLines <= streamingChunkLines {
		writeSSEEvent(w, flusher, aguiEventTextMessageContent, map[string]interface{}{
			"type":       aguiEventTextMessageContent,
			"message_id": messageID,
			"delta":      responseText,
		})
		return
	}

	// For longer responses, emit in line-grouped chunks
	for i := 0; i < totalLines; i += streamingChunkLines {
		end := i + streamingChunkLines
		if end > totalLines {
			end = totalLines
		}

		chunk := strings.Join(lines[i:end], "\n")
		// Add trailing newline for all chunks except the last
		if end < totalLines {
			chunk += "\n"
		}

		writeSSEEvent(w, flusher, aguiEventTextMessageContent, map[string]interface{}{
			"type":       aguiEventTextMessageContent,
			"message_id": messageID,
			"delta":      chunk,
		})
	}
}

// writeSSEEvent writes a single SSE event to the response writer.
func writeSSEEvent(w http.ResponseWriter, flusher http.Flusher, eventType string, data interface{}) {
	jsonData, err := json.Marshal(data)
	if err != nil {
		slog.Error("[AG-UI Compat] Failed to marshal SSE event", "type", eventType, "error", err)
		return
	}
	fmt.Fprintf(w, "event: %s\ndata: %s\n\n", eventType, string(jsonData))
	flusher.Flush()
}

