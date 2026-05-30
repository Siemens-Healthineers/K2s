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

// Lightweight Prometheus metrics - no external dependencies.
// Exposes /metrics in Prometheus text exposition format.

// counter is a thread-safe monotonic counter with labels.
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

// histogram is a simple histogram with fixed buckets.
type histogram struct {
	mu      sync.RWMutex
	buckets []float64
	series  map[string]*histogramData
}

type histogramData struct {
	counts []atomic.Int64
	sum    atomic.Int64 // stored as microseconds for precision
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

// a2aMetrics holds all metrics for the a2a-proxy.
var a2aMetrics = struct {
	requestsTotal      *counter
	requestDuration    *histogram
	autoConfirmsTotal  *counter
	upstreamErrorTotal *atomic.Int64
	taskCompletedTotal *counter
	taskDuration       *histogram
	ttftDuration       *histogram // time-to-first-token
	streamingTotal     *counter   // streaming completions by source
}{
	requestsTotal:      newCounter(),
	requestDuration:    newHistogram([]float64{0.1, 0.5, 1, 5, 10, 30, 60, 120}),
	autoConfirmsTotal:  newCounter(),
	upstreamErrorTotal: &atomic.Int64{},
	taskCompletedTotal: newCounter(),
	taskDuration:       newHistogram([]float64{1, 5, 10, 30, 60, 120, 300}),
	ttftDuration:       newHistogram([]float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5}),
	streamingTotal:     newCounter(),
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")

	var sb strings.Builder

	// a2a_proxy_requests_total
	sb.WriteString("# HELP a2a_proxy_requests_total Total A2A proxy requests\n")
	sb.WriteString("# TYPE a2a_proxy_requests_total counter\n")
	writeCounter(&sb, "a2a_proxy_requests_total", a2aMetrics.requestsTotal)

	// a2a_proxy_request_duration_seconds
	sb.WriteString("# HELP a2a_proxy_request_duration_seconds Request latency\n")
	sb.WriteString("# TYPE a2a_proxy_request_duration_seconds histogram\n")
	writeHistogram(&sb, "a2a_proxy_request_duration_seconds", a2aMetrics.requestDuration)

	// a2a_proxy_auto_confirms_total
	sb.WriteString("# HELP a2a_proxy_auto_confirms_total Auto-confirmation decisions\n")
	sb.WriteString("# TYPE a2a_proxy_auto_confirms_total counter\n")
	writeCounter(&sb, "a2a_proxy_auto_confirms_total", a2aMetrics.autoConfirmsTotal)

	// a2a_proxy_upstream_errors_total
	sb.WriteString("# HELP a2a_proxy_upstream_errors_total Upstream connection errors\n")
	sb.WriteString("# TYPE a2a_proxy_upstream_errors_total counter\n")
	fmt.Fprintf(&sb, "a2a_proxy_upstream_errors_total %d\n", a2aMetrics.upstreamErrorTotal.Load())

	// ai_assistant_task_completed_total
	sb.WriteString("# HELP ai_assistant_task_completed_total Tasks completed by state\n")
	sb.WriteString("# TYPE ai_assistant_task_completed_total counter\n")
	writeCounter(&sb, "ai_assistant_task_completed_total", a2aMetrics.taskCompletedTotal)

	// ai_assistant_task_duration_seconds
	sb.WriteString("# HELP ai_assistant_task_duration_seconds End-to-end task duration\n")
	sb.WriteString("# TYPE ai_assistant_task_duration_seconds histogram\n")
	writeHistogram(&sb, "ai_assistant_task_duration_seconds", a2aMetrics.taskDuration)

	// ai_assistant_ollama_reachable (gauge from Ollama monitor)
	writeOllamaMetric(&sb)

	// ai_assistant_ttft_seconds (time-to-first-token)
	sb.WriteString("# HELP ai_assistant_ttft_seconds Time-to-first-token (thinking indicator delivery)\n")
	sb.WriteString("# TYPE ai_assistant_ttft_seconds histogram\n")
	writeHistogram(&sb, "ai_assistant_ttft_seconds", a2aMetrics.ttftDuration)

	// ai_assistant_streaming_total (streaming completions by source)
	sb.WriteString("# HELP ai_assistant_streaming_total Streaming response completions\n")
	sb.WriteString("# TYPE ai_assistant_streaming_total counter\n")
	writeCounter(&sb, "ai_assistant_streaming_total", a2aMetrics.streamingTotal)

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

// recordRequest records a request metric.
func recordRequest(status string, duration time.Duration) {
	a2aMetrics.requestsTotal.Inc(fmt.Sprintf(`status="%s"`, status))
	a2aMetrics.requestDuration.Observe("", duration.Seconds())
}

// recordAutoConfirm records an auto-confirmation decision.
func recordAutoConfirm(tool, decision string) {
	a2aMetrics.autoConfirmsTotal.Inc(fmt.Sprintf(`tool="%s",decision="%s"`, tool, decision))
}

// recordUpstreamError records an upstream connectivity failure.
func recordUpstreamError() {
	a2aMetrics.upstreamErrorTotal.Add(1)
}

// recordTaskCompleted records a completed task with its final state.
func recordTaskCompleted(state string, duration time.Duration) {
	a2aMetrics.taskCompletedTotal.Inc(fmt.Sprintf(`state="%s"`, state))
	a2aMetrics.taskDuration.Observe("", duration.Seconds())
}

// recordTTFT records the time-to-first-token (thinking indicator delivery latency).
func recordTTFT(duration time.Duration) {
	a2aMetrics.ttftDuration.Observe("", duration.Seconds())
}

// recordStreamingCompletion records a streaming response completion.
func recordStreamingCompletion(source string, totalDuration, ttft time.Duration) {
	a2aMetrics.streamingTotal.Inc(fmt.Sprintf(`source="%s"`, source))
	a2aMetrics.requestDuration.Observe(fmt.Sprintf(`type="streaming",source="%s"`, source), totalDuration.Seconds())
}

