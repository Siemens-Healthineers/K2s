// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package linuxonly

import (
	"errors"
	"fmt"
	"strings"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
)

var ErrWslNotSupported = errors.New("linux-only in combination with WSL is currently not supported")

func BuildCmd(config *ic.InstallConfig) (cmd string, err error) {
	if config.Behavior.Wsl {
		return "", ErrWslNotSupported
	}

	controlPlaneNode, err := config.GetNodeByRole(ic.ControlPlaneRoleName)
	if err != nil {
		return "", err
	}

	path := fmt.Sprintf("%s\\lib\\scripts\\linuxonly\\install\\install.ps1", utils.InstallDir())
	formattedPath := utils.FormatScriptFilePath(path)
	cmd = fmt.Sprintf("%s -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		formattedPath,
		controlPlaneNode.Resources.Cpu,
		controlPlaneNode.Resources.Memory,
		controlPlaneNode.Resources.Disk)

	if controlPlaneNode.Resources.DynamicMemory {
		cmd += " -EnableDynamicMemory"
		if controlPlaneNode.Resources.MemoryMin != "" {
			cmd += " -MasterVMMemoryMin " + controlPlaneNode.Resources.MemoryMin
		}
		if controlPlaneNode.Resources.MemoryMax != "" {
			cmd += " -MasterVMMemoryMax " + controlPlaneNode.Resources.MemoryMax
		}
	}

	if config.Env.Proxy != "" {
		cmd += fmt.Sprintf(" -Proxy %s", config.Env.Proxy)
	}
	if len(config.Env.NoProxy) > 0 {
		cmd += fmt.Sprintf(" -NoProxy '%s'", strings.Join(config.Env.NoProxy, "','"))
	}
	if config.Env.AdditionalHooksDir != "" {
		cmd += fmt.Sprintf(" -AdditionalHooksDir '%s'", config.Env.AdditionalHooksDir)
	}
	if config.Behavior.ShowOutput {
		cmd += " -ShowLogs"
	}
	if config.Behavior.SkipStart {
		cmd += " -SkipStart"
	}
	if config.Behavior.DeleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}
	if config.Behavior.ForceOnlineInstallation {
		cmd += " -ForceOnlineInstallation"
	}
	if config.Behavior.AppendLog {
		cmd += " -AppendLogFile"
	}
	return cmd, nil
}
