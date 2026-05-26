// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"math"
	"net/http"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Lightweight Prometheus metrics for mcp-preprocessor.
// Exposes /metrics in Prometheus text exposition format.

type counter struct {
	mu     sync.RWMutex
	values map[string]*atomic.Int64
}

func newCounter() *counter {
	return &counter{values: make(map[string]*atomic.Int64)}
}

func (c *counter) Inc(labels string) {
	c.mu.RLock()
	v, ok := c.values[labels]
	c.mu.RUnlock()
	if ok {
		v.Add(1)
		return
	}
	c.mu.Lock()
	if v, ok = c.values[labels]; ok {
		c.mu.Unlock()
		v.Add(1)
		return
	}
	v = &atomic.Int64{}
	v.Store(1)
	c.values[labels] = v
	c.mu.Unlock()
}

func (c *counter) collect() map[string]int64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	result := make(map[string]int64, len(c.values))
	for k, v := range c.values {
		result[k] = v.Load()
	}
	return result
}

type histogram struct {
	mu      sync.RWMutex
	buckets []float64
	series  map[string]*histogramData
}

type histogramData struct {
	counts []atomic.Int64
	sum    atomic.Int64
	count  atomic.Int64
}

func newHistogram(buckets []float64) *histogram {
	return &histogram{
		buckets: buckets,
		series:  make(map[string]*histogramData),
	}
}

func (h *histogram) Observe(labels string, value float64) {
	h.mu.RLock()
	d, ok := h.series[labels]
	h.mu.RUnlock()
	if !ok {
		h.mu.Lock()
		if d, ok = h.series[labels]; !ok {
			d = &histogramData{counts: make([]atomic.Int64, len(h.buckets)+1)}
			h.series[labels] = d
		}
		h.mu.Unlock()
	}
	d.sum.Add(int64(value * 1e6))
	d.count.Add(1)
	for i, b := range h.buckets {
		if value <= b {
			d.counts[i].Add(1)
		}
	}
	d.counts[len(h.buckets)].Add(1) // +Inf
}

// mcpMetrics holds all metrics for the mcp-preprocessor.
var mcpMetrics = struct {
	requestsTotal      *counter
	requestDuration    *histogram
	truncationsTotal   *counter
	outputTokens       *histogram
	upstreamErrorTotal *atomic.Int64
}{
	requestsTotal:      newCounter(),
	requestDuration:    newHistogram([]float64{0.01, 0.05, 0.1, 0.5, 1, 5, 10, 30}),
	truncationsTotal:   newCounter(),
	outputTokens:       newHistogram([]float64{100, 500, 1000, 2000, 3000, 4096, 8000, 16000}),
	upstreamErrorTotal: &atomic.Int64{},
}

func mcpMetricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

	var sb strings.Builder

	// mcp_preprocessor_requests_total
	sb.WriteString("# HELP mcp_preprocessor_requests_total Total MCP tool call requests\n")
	sb.WriteString("# TYPE mcp_preprocessor_requests_total counter\n")
	writeCounter(&sb, "mcp_preprocessor_requests_total", mcpMetrics.requestsTotal)

	// mcp_preprocessor_request_duration_seconds
	sb.WriteString("# HELP mcp_preprocessor_request_duration_seconds Tool call latency including upstream\n")
	sb.WriteString("# TYPE mcp_preprocessor_request_duration_seconds histogram\n")
	writeHistogram(&sb, "mcp_preprocessor_request_duration_seconds", mcpMetrics.requestDuration)

	// mcp_preprocessor_truncations_total
	sb.WriteString("# HELP mcp_preprocessor_truncations_total Truncation events by tool and reason\n")
	sb.WriteString("# TYPE mcp_preprocessor_truncations_total counter\n")
	writeCounter(&sb, "mcp_preprocessor_truncations_total", mcpMetrics.truncationsTotal)

	// mcp_preprocessor_output_tokens
	sb.WriteString("# HELP mcp_preprocessor_output_tokens Pre-truncation token count distribution\n")
	sb.WriteString("# TYPE mcp_preprocessor_output_tokens histogram\n")
	writeHistogram(&sb, "mcp_preprocessor_output_tokens", mcpMetrics.outputTokens)

	// mcp_preprocessor_upstream_errors_total
	sb.WriteString("# HELP mcp_preprocessor_upstream_errors_total Upstream MCP server errors\n")
	sb.WriteString("# TYPE mcp_preprocessor_upstream_errors_total counter\n")
	fmt.Fprintf(&sb, "mcp_preprocessor_upstream_errors_total %d\n", mcpMetrics.upstreamErrorTotal.Load())

	_, _ = w.Write([]byte(sb.String()))
}

func writeCounter(sb *strings.Builder, name string, c *counter) {
	values := c.collect()
	keys := sortedKeys(values)
	for _, labels := range keys {
		v := values[labels]
		if labels == "" {
			fmt.Fprintf(sb, "%s %d\n", name, v)
		} else {
			fmt.Fprintf(sb, "%s{%s} %d\n", name, labels, v)
		}
	}
}

func writeHistogram(sb *strings.Builder, name string, h *histogram) {
	h.mu.RLock()
	defer h.mu.RUnlock()

	for labels, d := range h.series {
		labelPrefix := ""
		if labels != "" {
			labelPrefix = labels + ","
		}
		cumulative := int64(0)
		for i, b := range h.buckets {
			cumulative += d.counts[i].Load()
			fmt.Fprintf(sb, "%s_bucket{%sle=\"%s\"} %d\n", name, labelPrefix, formatFloat(b), cumulative)
		}
		total := d.count.Load()
		fmt.Fprintf(sb, "%s_bucket{%sle=\"+Inf\"} %d\n", name, labelPrefix, total)
		fmt.Fprintf(sb, "%s_sum{%s} %s\n", name, labels, formatFloat(float64(d.sum.Load())/1e6))
		fmt.Fprintf(sb, "%s_count{%s} %d\n", name, labels, total)
	}
}

func formatFloat(f float64) string {
	if f == math.Inf(1) {
		return "+Inf"
	}
	return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%.6f", f), "0"), ".")
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// recordMCPRequest records a tool call request.
func recordMCPRequest(tool, status string, duration time.Duration) {
	mcpMetrics.requestsTotal.Inc(fmt.Sprintf(`tool="%s",status="%s"`, tool, status))
	mcpMetrics.requestDuration.Observe(fmt.Sprintf(`tool="%s"`, tool), duration.Seconds())
}

// recordTruncation records a truncation event.
func recordTruncation(tool, reason string) {
	mcpMetrics.truncationsTotal.Inc(fmt.Sprintf(`tool="%s",reason="%s"`, tool, reason))
}

// recordOutputTokens records the pre-truncation token estimate.
func recordOutputTokens(tool string, tokens int) {
	mcpMetrics.outputTokens.Observe(fmt.Sprintf(`tool="%s"`, tool), float64(tokens))
}

// recordMCPUpstreamError records an upstream MCP server failure.
func recordMCPUpstreamError() {
	mcpMetrics.upstreamErrorTotal.Add(1)
}

