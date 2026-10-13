// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"strings"
	"testing"
)

func TestClusterUpgradeCommandEscapesConfigPath(t *testing.T) {
	provider := &windowsSystemProvider{installDir: `C:\K2s Package`}

	command := provider.clusterUpgradeCommand(SystemUpgradeConfig{
		ConfigFile: `C:\Upgrade Config\owner's.yaml`,
	})

	if !strings.Contains(command, ` -Config 'C:\Upgrade Config\owner''s.yaml'`) {
		t.Fatalf("cluster upgrade command does not safely quote config path: %s", command)
	}
}
