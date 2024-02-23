// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"errors"
	"k2s/cmd/common"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"
	"strings"

	p "k2s/cmd/params"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"k8s.io/klog/v2"
)

var (
	example = `
# Creates K2s package
k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip"

# Creates K2s package for offline installation
k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --for-offline-installation
`

	PackageCmd = &cobra.Command{
		Use:     "package",
		Short:   "Build K2s zip package",
		RunE:    systemPackage,
		Example: example,
	}
)

const (
	ControlPlaneCPUsFlagName  = "master-cpus"
	ControlPlaneCPUsFlagUsage = "Number of CPUs allocated to master VM"

	ControlPlaneMemoryFlagName  = "master-memory"
	ControlPlaneMemoryFlagUsage = "Amount of RAM to allocate to master VM (minimum 2GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ControlPlaneDiskSizeFlagName  = "master-disk"
	ControlPlaneDiskSizeFlagUsage = "Disk size allocated to the master VM (minimum 50GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ProxyFlagName  = "proxy"
	ProxyFlagUsage = "HTTP proxy if available to be used"

	TargetDirectoryFlagName  = "target-dir"
	TargetDirectoryFlagUsage = "Target directory"

	ZipPackageFileNameFlagName  = "name"
	ZipPackageFileNameFlagUsage = "The name of the zip package (it must have the extension .zip)"

	ForOfflineInstallationFlagName  = "for-offline-installation"
	ForOfflineInstallationFlagUsage = "Creates a zip package that can be used for offline installation"
)

func init() {
	PackageCmd.Flags().String(ControlPlaneCPUsFlagName, "", ControlPlaneCPUsFlagUsage)
	PackageCmd.Flags().String(ControlPlaneMemoryFlagName, "", ControlPlaneMemoryFlagUsage)
	PackageCmd.Flags().String(ControlPlaneDiskSizeFlagName, "", ControlPlaneDiskSizeFlagUsage)
	PackageCmd.Flags().StringP(ProxyFlagName, "p", "", ProxyFlagUsage)
	PackageCmd.Flags().StringP(TargetDirectoryFlagName, "d", "", TargetDirectoryFlagUsage)
	PackageCmd.Flags().StringP(ZipPackageFileNameFlagName, "n", "", ZipPackageFileNameFlagUsage)
	PackageCmd.Flags().Bool(ForOfflineInstallationFlagName, false, ForOfflineInstallationFlagUsage)
	PackageCmd.Flags().SortFlags = false
	PackageCmd.Flags().PrintDefaults()
}

func systemPackage(cmd *cobra.Command, args []string) error {
	systemPackageCommand, err := buildSystemPackageCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("system package command: %s", systemPackageCommand)

	params := []string{}

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", psexecutor.ExecOptions{IgnoreNotInstalledErr: true}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	return nil
}

func buildSystemPackageCmd(cmd *cobra.Command) (string, error) {
	systemPackageCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\BuildK2sZipPackage.ps1")

	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		klog.V(3).Infof("Param: %s: %s\n", f.Name, f.Value)
	})

	out, _ := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if out {
		systemPackageCommand += " -ShowLogs"
	}

	proxy := cmd.Flags().Lookup(ProxyFlagName).Value.String()
	if len(proxy) > 0 {
		systemPackageCommand += " -Proxy " + proxy
	}

	cpus := cmd.Flags().Lookup(ControlPlaneCPUsFlagName).Value.String()
	if len(cpus) > 0 {
		systemPackageCommand += " -VMProcessorCount " + cpus
	}

	memory := cmd.Flags().Lookup(ControlPlaneMemoryFlagName).Value.String()
	if len(memory) > 0 {
		systemPackageCommand += " -VMMemoryStartupBytes " + memory
	}

	disksize := cmd.Flags().Lookup(ControlPlaneDiskSizeFlagName).Value.String()
	if len(disksize) > 0 {
		systemPackageCommand += " -VMDiskSize " + disksize
	}

	targetDir := cmd.Flags().Lookup(TargetDirectoryFlagName).Value.String()
	if len(targetDir) == 0 {
		return "", errors.New("no target directory path provided")
	}
	systemPackageCommand += " -TargetDirectory " + utils.EscapeWithSingleQuotes(targetDir)

	name := cmd.Flags().Lookup(ZipPackageFileNameFlagName).Value.String()
	if len(name) == 0 {
		return "", errors.New("no package file name provided")
	}
	if !strings.Contains(name, ".zip") {
		return "", errors.New("package file name does not contain '.zip'")
	}
	systemPackageCommand += " -ZipPackageFileName " + name

	forOfflineInstallation, _ := strconv.ParseBool(cmd.Flags().Lookup(ForOfflineInstallationFlagName).Value.String())
	if forOfflineInstallation {
		systemPackageCommand += " -ForOfflineInstallation"
	}

	return systemPackageCommand, nil
}
