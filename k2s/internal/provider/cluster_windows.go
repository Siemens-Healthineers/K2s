// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	k2sos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type windowsClusterProvider struct {
	installDir string
	stdWriter  k2sos.StdWriter
}

func newWindowsClusterProvider(cfg ProviderConfig) *windowsClusterProvider {
	return &windowsClusterProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsClusterProvider) Install(cfg ClusterInstallConfig) error {
<<<<<<< HEAD
	if cfg.LinuxOnly && cfg.WSL {
		return errors.New("linux-only in combination with WSL is currently not supported")
	}

	setup := p.resolveSetupDir(cfg.SetupName, cfg.LinuxOnly)
	path := filepath.Join(p.installDir, "lib", "scripts", setup, "install", "install.ps1")
=======
	path := filepath.Join(p.installDir, "lib", "scripts", "k2s", "install", "install.ps1")
>>>>>>> main
	cmd := utils.FormatScriptFilePath(path)
	cmd += fmt.Sprintf(" -MasterVMProcessorCount %s -MasterVMMemory %s -MasterDiskSize %s",
		cfg.MasterVMProcessorCount, cfg.MasterVMMemory, cfg.MasterDiskSize)

	if cfg.DynamicMemory {
		cmd += " -EnableDynamicMemory"
		if cfg.MasterVMMemoryMin != "" {
			cmd += " -MasterVMMemoryMin " + cfg.MasterVMMemoryMin
		}
		if cfg.MasterVMMemoryMax != "" {
			cmd += " -MasterVMMemoryMax " + cfg.MasterVMMemoryMax
		}
	}
	if cfg.Proxy != "" {
		cmd += " -Proxy " + cfg.Proxy
	}
	if len(cfg.NoProxy) > 0 {
		cmd += fmt.Sprintf(" -NoProxy '%s'", strings.Join(cfg.NoProxy, "','"))
	}
	if cfg.AdditionalHooksDir != "" {
		cmd += fmt.Sprintf(" -AdditionalHooksDir '%s'", cfg.AdditionalHooksDir)
	}
<<<<<<< HEAD
	// RestartAfterInstallCount, K8sBinsPath, and WSL are only supported by the k2s install script,
	// not by the linuxonly install script.
	if !cfg.LinuxOnly {
		if cfg.RestartPostInstall != "" {
			cmd += fmt.Sprintf(" -RestartAfterInstallCount %s", cfg.RestartPostInstall)
		}
		if cfg.K8sBinsPath != "" {
			cmd += fmt.Sprintf(" -K8sBinsPath '%s'", cfg.K8sBinsPath)
		}
		if cfg.WSL {
			cmd += " -WSL"
		}
=======
	if cfg.RestartPostInstall != "" {
		cmd += fmt.Sprintf(" -RestartAfterInstallCount %s", cfg.RestartPostInstall)
	}
	if cfg.K8sBinsPath != "" {
		cmd += fmt.Sprintf(" -K8sBinsPath '%s'", cfg.K8sBinsPath)
>>>>>>> main
	}
	if cfg.ShowLogs {
		cmd += " -ShowLogs"
	}
	if cfg.SkipStart {
		cmd += " -SkipStart"
	}
	if cfg.DeleteFilesForOfflineInstallation {
		cmd += " -DeleteFilesForOfflineInstallation"
	}
	if cfg.ForceOnlineInstallation {
		cmd += " -ForceOnlineInstallation"
	}
<<<<<<< HEAD
=======
	if cfg.LinuxOnly {
		cmd += " -LinuxOnly"
	}
	if cfg.WSL {
		cmd += " -WSL"
	}
>>>>>>> main
	if cfg.AppendLog {
		cmd += " -AppendLogFile"
	}

	writer := cfg.StdWriter
	if writer == nil {
		writer = p.stdWriter
	}

	return powershell.ExecutePs(cmd, writer)
}

func (p *windowsClusterProvider) Uninstall(cfg ClusterUninstallConfig) error {
	var cmd string

	setup := p.resolveSetupDir(cfg.SetupName, cfg.LinuxOnly)

	switch cfg.SetupName {
	case definitions.SetupNameBuildOnlyEnv:
		path := filepath.Join(p.installDir, "lib", "scripts", "buildonly", "uninstall", "uninstall.ps1")
		cmd = utils.FormatScriptFilePath(path)
		if cfg.ShowLogs {
			cmd += " -ShowLogs"
		}
		if cfg.DeleteFilesForOfflineInstallation {
			cmd += " -DeleteFilesForOfflineInstallation"
		}
	default:
		path := filepath.Join(p.installDir, "lib", "scripts", setup, "uninstall", "uninstall.ps1")
		cmd = utils.FormatScriptFilePath(path)
		if cfg.SkipPurge {
			cmd += " -SkipPurge"
		}
		if cfg.ShowLogs {
			cmd += " -ShowLogs"
		}
		if cfg.AdditionalHooksDir != "" {
			cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
		}
		if cfg.DeleteFilesForOfflineInstallation {
			cmd += " -DeleteFilesForOfflineInstallation"
		}
	}

	return powershell.ExecutePs(cmd, p.stdWriter)
}

func (p *windowsClusterProvider) Start(cfg ClusterStartConfig) error {
	switch cfg.SetupName {
	case definitions.SetupNameBuildOnlyEnv:
		return errors.New("there is no cluster to start in build-only setup mode ;-). Aborting")
	}

	setup := p.resolveSetupDir(cfg.SetupName, cfg.LinuxOnly)
	path := filepath.Join(p.installDir, "lib", "scripts", setup, "start", "start.ps1")
	cmd := utils.FormatScriptFilePath(path)

	if cfg.ShowLogs {
		cmd += " -ShowLogs"
	}
	if cfg.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
	}
	if cfg.UseCachedK2sVSwitch && !cfg.LinuxOnly {
		cmd += " -UseCachedK2sVSwitches"
	}

	return powershell.ExecutePs(cmd, p.stdWriter)
}

func (p *windowsClusterProvider) Stop(cfg ClusterStopConfig) error {
	switch cfg.SetupName {
	case definitions.SetupNameBuildOnlyEnv:
		return errors.New("there is no cluster to stop in build-only setup mode ;-). Aborting")
	}

	setup := p.resolveSetupDir(cfg.SetupName, cfg.LinuxOnly)
	path := filepath.Join(p.installDir, "lib", "scripts", setup, "stop", "stop.ps1")
	cmd := utils.FormatScriptFilePath(path)

	if cfg.ShowLogs {
		cmd += " -ShowLogs"
	}
	if cfg.AdditionalHooksDir != "" {
		cmd += " -AdditionalHooksDir " + utils.EscapeWithSingleQuotes(cfg.AdditionalHooksDir)
	}
	if cfg.CacheVSwitch && !cfg.LinuxOnly {
		cmd += " -CacheK2sVSwitches"
	}

	return powershell.ExecutePs(cmd, p.stdWriter)
}

// resolveSetupDir returns the script subdirectory based on setup name and linux-only flag.
func (p *windowsClusterProvider) resolveSetupDir(setupName string, linuxOnly bool) string {
	switch setupName {
	case definitions.SetupNameK2s:
		if linuxOnly {
			return "linuxonly"
		}
		return "k2s"
	default:
		return "k2s"
	}
}

func (p *windowsClusterProvider) Status(cfg ClusterStatusConfig) (*ClusterStatus, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "lib", "scripts", "k2s", "status", "Get-Status.ps1"))

	type psStatus struct {
		RunningState *struct {
			IsRunning bool     `json:"isRunning"`
			Issues    []string `json:"issues"`
		} `json:"runningState"`
		Nodes []struct {
			Name             string `json:"name"`
			Status           string `json:"status"`
			Role             string `json:"role"`
			Age              string `json:"age"`
			KubeletVersion   string `json:"kubeletVersion"`
			KernelVersion    string `json:"kernelVersion"`
			OsImage          string `json:"osImage"`
			ContainerRuntime string `json:"containerRuntime"`
			InternalIp       string `json:"internalIp"`
			IsReady          bool   `json:"isReady"`
			Capacity         struct {
				Cpu     string `json:"cpu"`
				Storage string `json:"storage"`
				Memory  string `json:"memory"`
			} `json:"capacity"`
		} `json:"nodes"`
		Pods []struct {
			Name      string `json:"name"`
			Namespace string `json:"namespace"`
			Status    string `json:"status"`
			Ready     string `json:"ready"`
			Restarts  string `json:"restarts"`
			Age       string `json:"age"`
			Ip        string `json:"ip"`
			Node      string `json:"node"`
			IsRunning bool   `json:"isRunning"`
		} `json:"pods"`
		K8sVersionInfo *struct {
			K8sServerVersion string `json:"k8sServerVersion"`
			K8sClientVersion string `json:"k8sClientVersion"`
		} `json:"k8sVersionInfo"`
	}

	// Use structured result from PS
	type wrappedResult struct {
		Failure *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"failure"`
		psStatus
	}

	result, err := powershell.ExecutePsWithStructuredResult[*wrappedResult](scriptPath, "CmdResult", p.stdWriter)
	if err != nil {
		return nil, err
	}

	status := &ClusterStatus{}
	if result.RunningState != nil {
		status.IsRunning = result.RunningState.IsRunning
		status.Issues = result.RunningState.Issues
	}
	if result.K8sVersionInfo != nil {
<<<<<<< HEAD
		status.K8sVersionInfo = &K8sVersionInfo{
			K8sServerVersion: result.K8sVersionInfo.K8sServerVersion,
			K8sClientVersion: result.K8sVersionInfo.K8sClientVersion,
		}
=======
		status.K8sServerVer = result.K8sVersionInfo.K8sServerVersion
		status.K8sClientVer = result.K8sVersionInfo.K8sClientVersion
>>>>>>> main
	}

	for _, n := range result.Nodes {
		status.Nodes = append(status.Nodes, NodeStatus{
			Name:             n.Name,
			Status:           n.Status,
			Role:             n.Role,
			Age:              n.Age,
			KubeletVersion:   n.KubeletVersion,
			KernelVersion:    n.KernelVersion,
			OsImage:          n.OsImage,
			ContainerRuntime: n.ContainerRuntime,
			InternalIp:       n.InternalIp,
			IsReady:          n.IsReady,
<<<<<<< HEAD
			Capacity: NodeCapacity{
				Cpu:     n.Capacity.Cpu,
				Memory:  n.Capacity.Memory,
				Storage: n.Capacity.Storage,
			},
=======
			CpuCapacity:      n.Capacity.Cpu,
			MemoryCapacity:   n.Capacity.Memory,
			StorageCapacity:  n.Capacity.Storage,
>>>>>>> main
		})
	}

	for _, pod := range result.Pods {
		status.Pods = append(status.Pods, PodStatus{
			Name:      pod.Name,
			Namespace: pod.Namespace,
			Status:    pod.Status,
			Ready:     pod.Ready,
			Restarts:  pod.Restarts,
			Age:       pod.Age,
			Ip:        pod.Ip,
			Node:      pod.Node,
			IsRunning: pod.IsRunning,
		})
	}

	return status, nil
}
