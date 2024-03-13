// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"errors"
	"log/slog"
	"strconv"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	p "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
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
	systemPackageCommand, params, err := buildSystemPackageCmd(cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", systemPackageCommand, "params", params)

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", psexecutor.ExecOptions{IgnoreNotInstalledErr: true}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	return nil
}

func buildSystemPackageCmd(cmd *cobra.Command) (string, []string, error) {
	systemPackageCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\BuildK2sZipPackage.ps1")

	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		slog.Debug("Param", "name", f.Name, "value", f.Value)
	})

	params := []string{}

	out, _ := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if out {
		params = append(params, " -ShowLogs")
	}

	proxy := cmd.Flags().Lookup(ProxyFlagName).Value.String()
	if len(proxy) > 0 {
		params = append(params, " -Proxy "+proxy)
	}

	cpus := cmd.Flags().Lookup(ControlPlaneCPUsFlagName).Value.String()
	if len(cpus) > 0 {
		params = append(params, " -VMProcessorCount "+cpus)
	}

	memory := cmd.Flags().Lookup(ControlPlaneMemoryFlagName).Value.String()
	if len(memory) > 0 {
		params = append(params, " -VMMemoryStartupBytes "+memory)
	}

	disksize := cmd.Flags().Lookup(ControlPlaneDiskSizeFlagName).Value.String()
	if len(disksize) > 0 {
		params = append(params, " -VMDiskSize "+disksize)
	}

	targetDir := cmd.Flags().Lookup(TargetDirectoryFlagName).Value.String()
	if len(targetDir) == 0 {
		return "", nil, errors.New("no target directory path provided")
	}
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))

	name := cmd.Flags().Lookup(ZipPackageFileNameFlagName).Value.String()
	if len(name) == 0 {
		return "", nil, errors.New("no package file name provided")
	}
	if !strings.Contains(name, ".zip") {
		return "", nil, errors.New("package file name does not contain '.zip'")
	}
	params = append(params, " -ZipPackageFileName "+name)

	forOfflineInstallation, _ := strconv.ParseBool(cmd.Flags().Lookup(ForOfflineInstallationFlagName).Value.String())
	if forOfflineInstallation {
		params = append(params, " -ForOfflineInstallation")
	}

	return systemPackageCommand, params, nil
}
