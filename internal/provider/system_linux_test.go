// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

//go:build linux

package provider

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLinuxSystemProviderResetDoesNotRunNetworkCleanup(t *testing.T) {
	t.Parallel()

	installDir := t.TempDir()
	configDir := t.TempDir()
	scriptPath := filepath.Join(installDir, "lib", "scripts", "linux", "debian", "linuxonly", "Uninstall.sh")
	if err := os.MkdirAll(filepath.Dir(scriptPath), 0o755); err != nil {
		t.Fatalf("create uninstall script dir: %v", err)
	}
	if err := os.WriteFile(scriptPath, []byte("#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write uninstall script: %v", err)
	}

	originalRunCombinedOutput := linuxRunCombinedOutput
	t.Cleanup(func() {
		linuxRunCombinedOutput = originalRunCombinedOutput
	})

	var calls []string
	linuxRunCombinedOutput = func(name string, args ...string) ([]byte, error) {
		call := name
		for _, arg := range args {
			call += " " + arg
		}
		calls = append(calls, call)
		return nil, nil
	}

	provider := newLinuxSystemProvider(ProviderConfig{InstallDir: installDir, ConfigDir: configDir})
	if err := provider.Reset(SystemResetConfig{}); err != nil {
		t.Fatalf("reset failed: %v", err)
	}

	if len(calls) != 0 {
		t.Fatalf("expected reset to avoid standalone network cleanup, got calls: %v", calls)
	}
}