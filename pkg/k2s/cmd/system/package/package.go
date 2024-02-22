// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"k2s/cmd/common"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"

	p "k2s/cmd/params"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"k8s.io/klog/v2"
)

var (
	example = `
	k2s system package 
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
	resetSystemCommand, err := buildSystemPackageCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("system package command: %s", resetSystemCommand)

	duration, err := psexecutor.ExecutePowershellScript(resetSystemCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "system package")

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

	return systemPackageCommand, nil
}
