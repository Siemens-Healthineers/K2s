// SPDX-FileCopyrightText: © 2025 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"testing"
)

func TestExtractToolConfirmation_ApprovedTool(t *testing.T) {
	result := taskResult{
		ID:     "task-123",
		Status: taskStatus{State: "input-required"},
		History: []message{
			{
				Role: "agent",
				Parts: []part{
					{Text: "I need to confirm: shall I call k8s_get_resources?"},
				},
			},
		},
	}

	tool := extractToolConfirmation(result)
	if tool != "k8s_get_resources" {
		t.Errorf("expected k8s_get_resources, got %q", tool)
	}
}

func TestExtractToolConfirmation_NonApprovedTool(t *testing.T) {
	result := taskResult{
		ID:     "task-456",
		Status: taskStatus{State: "input-required"},
		History: []message{
			{
				Role: "agent",
				Parts: []part{
					{Text: "I need to confirm: shall I call k8s_delete_resource?"},
				},
			},
		},
	}

	tool := extractToolConfirmation(result)
	if tool != "" {
		t.Errorf("expected empty string for non-approved tool, got %q", tool)
	}
}

func TestExtractToolConfirmation_NoConfirmation(t *testing.T) {
	result := taskResult{
		ID:     "task-789",
		Status: taskStatus{State: "input-required"},
		History: []message{
			{
				Role: "agent",
				Parts: []part{
					{Text: "What namespace would you like me to check?"},
				},
			},
		},
	}

	tool := extractToolConfirmation(result)
	if tool != "" {
		t.Errorf("expected empty string for non-confirmation, got %q", tool)
	}
}

func TestExtractToolConfirmation_ToolNameInPart(t *testing.T) {
	result := taskResult{
		ID:     "task-abc",
		Status: taskStatus{State: "input-required"},
		History: []message{
			{
				Role: "agent",
				Parts: []part{
					{ToolName: "k8s_get_pod_logs", Text: "confirm execution"},
				},
			},
		},
	}

	tool := extractToolConfirmation(result)
	if tool != "k8s_get_pod_logs" {
		t.Errorf("expected k8s_get_pod_logs, got %q", tool)
	}
}

func TestExtractToolConfirmation_ToolNameInPartNonApproved(t *testing.T) {
	result := taskResult{
		ID:     "task-def",
		Status: taskStatus{State: "input-required"},
		History: []message{
			{
				Role: "agent",
				Parts: []part{
					{ToolName: "k8s_apply_resource", Text: "confirm execution"},
				},
			},
		},
	}

	// The ToolName field returns the tool regardless of approval status
	// The approval check happens in maybeAutoConfirm, not extractToolConfirmation
	tool := extractToolConfirmation(result)
	if tool != "k8s_apply_resource" {
		t.Errorf("expected k8s_apply_resource (extraction only), got %q", tool)
	}
}

func TestApprovedToolsList(t *testing.T) {
	expected := []string{
		"k8s_get_resources",
		"k8s_describe_resource",
		"k8s_get_pod_logs",
		"k8s_get_events",
		"k8s_get_resource_yaml",
	}

	for _, tool := range expected {
		if !approvedTools[tool] {
			t.Errorf("expected %q to be in approvedTools", tool)
		}
	}

	// Verify write tools are NOT approved
	forbidden := []string{
		"k8s_delete_resource",
		"k8s_apply_resource",
		"k8s_patch_resource",
		"k8s_exec",
		"ask_user",
	}
	for _, tool := range forbidden {
		if approvedTools[tool] {
			t.Errorf("expected %q to NOT be in approvedTools", tool)
		}
	}
}

func TestA2AResponseParsing(t *testing.T) {
	// Simulate a typical input-required response from Kagent
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 1,
		"result": {
			"id": "task-abc-123",
			"status": {
				"state": "input-required",
				"message": {
					"role": "agent",
					"parts": [{"text": "adk_request_confirmation: k8s_get_resources"}]
				}
			},
			"history": []
		}
	}`

	var a2aResp a2aResponse
	if err := json.Unmarshal([]byte(responseJSON), &a2aResp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	var result taskResult
	if err := json.Unmarshal(a2aResp.Result, &result); err != nil {
		t.Fatalf("failed to parse result: %v", err)
	}

	if result.Status.State != "input-required" {
		t.Errorf("expected input-required, got %q", result.Status.State)
	}

	tool := extractToolConfirmation(result)
	if tool != "k8s_get_resources" {
		t.Errorf("expected k8s_get_resources, got %q", tool)
	}
}

func TestA2ACompletedResponsePassthrough(t *testing.T) {
	responseJSON := `{
		"jsonrpc": "2.0",
		"id": 1,
		"result": {
			"id": "task-abc-123",
			"status": {"state": "completed"},
			"history": []
		}
	}`

	var a2aResp a2aResponse
	if err := json.Unmarshal([]byte(responseJSON), &a2aResp); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	var result taskResult
	if err := json.Unmarshal(a2aResp.Result, &result); err != nil {
		t.Fatalf("failed to parse result: %v", err)
	}

	// Completed responses should not trigger confirmation
	if result.Status.State == "input-required" {
		t.Error("completed response should not need confirmation")
	}
}

