// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

var (
	example = `
# Creates K2s package
k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip"

# Creates K2s package for offline installation
k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --for-offline-installation

Note: If offline artifacts are not already available due to previous installation, a 'Development Only Variant' will be installed during package creation and removed afterwards again
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
	systemPackageCommand, params, err := buildSystemPackageCmd(cmd.Flags())
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", systemPackageCommand, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	setupConfig, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
	}
	if err == nil && setupConfig.SetupName != "" {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' is installed on your system. Please uninstall '%s' first and try again.", setupConfig.SetupName, setupConfig.SetupName),
		}
	}

	start := time.Now()

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", powershell.DefaultPsVersions, common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, "system package")

	return nil
}

func buildSystemPackageCmd(flags *pflag.FlagSet) (string, []string, error) {
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1"))

	flags.VisitAll(func(f *pflag.Flag) {
		slog.Debug("Param", "name", f.Name, "value", f.Value)
	})

	params := []string{}

	out, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	if out {
		params = append(params, " -ShowLogs")
	}

	proxy := flags.Lookup(ProxyFlagName).Value.String()
	if len(proxy) > 0 {
		params = append(params, " -Proxy "+proxy)
	}

	cpus := flags.Lookup(ControlPlaneCPUsFlagName).Value.String()
	if len(cpus) > 0 {
		params = append(params, " -VMProcessorCount "+cpus)
	}

	memory := flags.Lookup(ControlPlaneMemoryFlagName).Value.String()
	if len(memory) > 0 {
		params = append(params, " -VMMemoryStartupBytes "+memory)
	}

	disksize := flags.Lookup(ControlPlaneDiskSizeFlagName).Value.String()
	if len(disksize) > 0 {
		params = append(params, " -VMDiskSize "+disksize)
	}

	targetDir := flags.Lookup(TargetDirectoryFlagName).Value.String()
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))

	name := flags.Lookup(ZipPackageFileNameFlagName).Value.String()
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(name))

	forOfflineInstallation, _ := strconv.ParseBool(flags.Lookup(ForOfflineInstallationFlagName).Value.String())
	if forOfflineInstallation {
		params = append(params, " -ForOfflineInstallation")
	}

	return systemPackageCommand, params, nil
}
