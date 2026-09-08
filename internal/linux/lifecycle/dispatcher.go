// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package lifecycle

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
)

// Operation carries non-secret lifecycle inputs. The shell reads registry.dat
// itself so credentials never appear in this operation document.
type Operation struct {
	InstallDir           string   `json:"installDir"`
	ConfigDir            string   `json:"configDir"`
	Version              string   `json:"version"`
	ClusterName          string   `json:"clusterName"`
	ControlPlaneHostname string   `json:"controlPlaneHostname"`
	Proxy                string   `json:"proxy"`
	NoProxy              []string `json:"noProxy"`
	SkipStart            bool     `json:"skipStart"`
	SkipPurge            bool     `json:"skipPurge"`
	LinuxOnly            bool     `json:"linuxOnly"`
}

// Execute invokes the platform-first native Linux lifecycle script.
func Execute(operation string, input Operation) error {
	script, err := ScriptPath(input.InstallDir, LinuxOnly, operation)
	if err != nil {
		return err
	}
	if _, err := os.Stat(script); err != nil {
		return fmt.Errorf("native Linux lifecycle script %s: %w", script, err)
	}
	if err := os.MkdirAll(input.ConfigDir, 0700); err != nil {
		return fmt.Errorf("create lifecycle state directory: %w", err)
	}
	file, err := os.CreateTemp(input.ConfigDir, ".lifecycle-*.json")
	if err != nil {
		return fmt.Errorf("create lifecycle operation file: %w", err)
	}
	path := file.Name()
	defer os.Remove(path)
	if err := file.Chmod(0600); err != nil {
		file.Close()
		return fmt.Errorf("secure lifecycle operation file: %w", err)
	}
	if err := json.NewEncoder(file).Encode(input); err != nil {
		file.Close()
		return fmt.Errorf("write lifecycle operation file: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close lifecycle operation file: %w", err)
	}

	cmd := exec.Command("bash", script, "--operation-file", path)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("native Linux %s failed: %w", operation, err)
	}
	return nil
}
