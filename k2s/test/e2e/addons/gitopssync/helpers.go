// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Package gitopssync provides shared helper functions for GitOps addon-sync e2e tests.
package gitopssync

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/siemens-healthineers/k2s/test/framework"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

// TarExe returns the tar executable name used on Windows.
func TarExe() string {
	return "tar.exe"
}

// SafeTrim returns at most maxLen characters from the end of s.
func SafeTrim(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return "..." + s[len(s)-maxLen:]
}

// WaitForJobCompletion polls until the named Job reaches Complete or Failed (max 10 min).
// It does NOT assert success; callers should explicitly check the Job condition afterwards.
func WaitForJobCompletion(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) {
	Eventually(func() bool {
		output, exitCode := suite.Kubectl().Exec(ctx,
			"get", "job", jobName,
			"-n", namespace,
			"-o", "jsonpath={.status.conditions[*].type}")
		if exitCode != 0 {
			GinkgoWriter.Printf("[Wait] kubectl get job failed (exit %d)\n", exitCode)
			return false
		}
		done := strings.Contains(output, "Complete") || strings.Contains(output, "Failed")
		if !done {
			GinkgoWriter.Printf("[Wait] Job %s not yet done, current conditions: %q\n", jobName, output)
		}
		return done
	}, 10*time.Minute, 15*time.Second, ctx).Should(BeTrue(),
		"Job %s should reach Complete or Failed within 10 minutes", jobName)
}

// WaitForJobToFinish polls until the named Job reaches Complete or Failed (max 10 min)
// without asserting success. Used in negative-path tests where pod failure is expected.
func WaitForJobToFinish(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) {
	Eventually(func() bool {
		output, exitCode := suite.Kubectl().Exec(ctx,
			"get", "job", jobName,
			"-n", namespace,
			"-o", "jsonpath={.status.conditions[*].type}")
		if exitCode != 0 {
			return false
		}
		return strings.Contains(output, "Complete") || strings.Contains(output, "Failed")
	}, 10*time.Minute, 15*time.Second, ctx).Should(BeTrue(),
		"Job %s should reach Complete or Failed within 10 minutes", jobName)
}

// GetJobLogs returns the combined stdout logs of all pods owned by the named Job.
func GetJobLogs(ctx context.Context, suite *framework.K2sTestSuite, namespace, jobName string) string {
	output, exitCode := suite.Kubectl().Exec(ctx,
		"logs", "-n", namespace,
		"--selector=job-name="+jobName,
		"--tail=-1")
	if exitCode != 0 {
		GinkgoWriter.Printf("[Logs] kubectl logs exited with %d, retrying with pod list\n", exitCode)
		podsOutput, _ := suite.Kubectl().Exec(ctx,
			"get", "pods", "-n", namespace,
			"-l", "job-name="+jobName,
			"-o", "jsonpath={.items[0].metadata.name}")
		if podsOutput != "" {
			podName := strings.TrimSpace(podsOutput)
			output, _ = suite.Kubectl().Exec(ctx, "logs", podName, "-n", namespace)
		}
	}
	return output
}

// ReadTagFromOCILayout parses the OCI Image Layout index.json in layoutDir and
// returns the first tag found via the org.opencontainers.image.ref.name annotation.
// This avoids hardcoding the addon version in test code.
func ReadTagFromOCILayout(layoutDir string) (string, error) {
	data, err := os.ReadFile(filepath.Join(layoutDir, "index.json"))
	if err != nil {
		return "", fmt.Errorf("read index.json: %w", err)
	}
	var index struct {
		Manifests []struct {
			Annotations map[string]string `json:"annotations"`
		} `json:"manifests"`
	}
	if err = json.Unmarshal(data, &index); err != nil {
		return "", fmt.Errorf("parse index.json: %w", err)
	}
	if len(index.Manifests) == 0 {
		return "", fmt.Errorf("index.json contains no manifests")
	}
	tag, ok := index.Manifests[0].Annotations["org.opencontainers.image.ref.name"]
	if !ok || tag == "" {
		return "", fmt.Errorf("index.json manifest[0] has no org.opencontainers.image.ref.name annotation")
	}
	return tag, nil
}

// CreateDummyOCILayout builds a minimal OCI Image Layout directory containing
// a single artifact tagged as tag. The manifest layer carries media type
// "application/octet-stream" — intentionally wrong — so that the sync consumer
// fails to find the expected "application/vnd.k2s.addon.manifests.v1.tar+gzip"
// layer. Returns the layout directory; callers must remove it with os.RemoveAll.
func CreateDummyOCILayout(tag string) (string, error) {
	dir, err := os.MkdirTemp("", "k2s-oci-layout-neg-*")
	if err != nil {
		return "", fmt.Errorf("MkdirTemp: %w", err)
	}

	blobsDir := filepath.Join(dir, "blobs", "sha256")
	if mkErr := os.MkdirAll(blobsDir, 0755); mkErr != nil {
		return dir, fmt.Errorf("MkdirAll blobs: %w", mkErr)
	}

	writeBlob := func(content []byte) (string, int64, error) {
		sum := sha256.Sum256(content)
		hexStr := hex.EncodeToString(sum[:])
		if wErr := os.WriteFile(filepath.Join(blobsDir, hexStr), content, 0644); wErr != nil {
			return "", 0, wErr
		}
		return "sha256:" + hexStr, int64(len(content)), nil
	}

	configDigest, configSize, err := writeBlob([]byte("{}"))
	if err != nil {
		return dir, fmt.Errorf("write config blob: %w", err)
	}

	layerDigest, layerSize, err := writeBlob([]byte("not a k2s addon manifests layer"))
	if err != nil {
		return dir, fmt.Errorf("write layer blob: %w", err)
	}

	manifestBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.manifest.v1+json",
		"config": map[string]any{
			"mediaType": "application/vnd.oci.image.config.v1+json",
			"digest":    configDigest,
			"size":      configSize,
		},
		"layers": []any{
			map[string]any{
				// Intentionally wrong — not application/vnd.k2s.addon.manifests.v1.tar+gzip
				"mediaType": "application/octet-stream",
				"digest":    layerDigest,
				"size":      layerSize,
			},
		},
	})
	if err != nil {
		return dir, fmt.Errorf("marshal manifest: %w", err)
	}

	manifestDigest, manifestSize, err := writeBlob(manifestBytes)
	if err != nil {
		return dir, fmt.Errorf("write manifest blob: %w", err)
	}

	indexBytes, err := json.Marshal(map[string]any{
		"schemaVersion": 2,
		"mediaType":     "application/vnd.oci.image.index.v1+json",
		"manifests": []any{
			map[string]any{
				"mediaType": "application/vnd.oci.image.manifest.v1+json",
				"digest":    manifestDigest,
				"size":      manifestSize,
				"annotations": map[string]string{
					"org.opencontainers.image.ref.name": tag,
				},
			},
		},
	})
	if err != nil {
		return dir, fmt.Errorf("marshal index: %w", err)
	}

	if err = os.WriteFile(filepath.Join(dir, "index.json"), indexBytes, 0644); err != nil {
		return dir, fmt.Errorf("write index.json: %w", err)
	}
	if err = os.WriteFile(filepath.Join(dir, "oci-layout"),
		[]byte(`{"imageLayoutVersion":"1.0.0"}`), 0644); err != nil {
		return dir, fmt.Errorf("write oci-layout: %w", err)
	}
	return dir, nil
}
