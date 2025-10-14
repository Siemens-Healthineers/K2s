// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"

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

	# Creates K2s package with code signing (certificate and password are both required)
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --certificate "path\to\cert.pfx" --password "mycertpassword"

	# Creates K2s package for offline installation with code signing
	k2s system package --target-dir "C:\tmp" --name "k2sZipFilePackage.zip" --for-offline-installation --certificate "path\to\cert.pfx" --password "mycertpassword"

	# Creates a delta package (provide full package zip paths)
	[EXPERIMENTAL]
	k2s system package --delta-package --target-dir "C:\tmp" --name "k2s-delta-1.4.0-to-1.4.1.zip" --package-version-from "C:\tmp\k2s-1.4.0.zip" --package-version-to "C:\tmp\k2s-1.4.1.zip"

	# Creates a signed delta package
	[EXPERIMENTAL]
	k2s system package --delta-package --target-dir "C:\tmp" --name "k2s-delta-1.4.0-to-1.4.1.zip" --package-version-from "C:\tmp\k2s-1.4.0.zip" --package-version-to "C:\tmp\k2s-1.4.1.zip" --certificate "path\to\cert.pfx" --password "mycertpassword"

	Note: If offline artifacts are not already available due to previous installation, a 'Development Only Variant' will be installed during package creation and removed afterwards again
	`

	PackageCmd = &cobra.Command{
		Use:     "package",
		Short:   "Build K2s zip package with optional code signing",
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
	ControlPlaneDiskSizeFlagUsage = "Disk size allocated to the master VM (minimum 10GB, format: <number>[<unit>], where unit = KB, MB or GB)"

	ProxyFlagName  = "proxy"
	ProxyFlagUsage = "HTTP proxy if available to be used"

	TargetDirectoryFlagName  = "target-dir"
	TargetDirectoryFlagUsage = "Target directory"

	ZipPackageFileNameFlagName  = "name"
	ZipPackageFileNameFlagUsage = "The name of the zip package (it must have the extension .zip)"

	ForOfflineInstallationFlagName  = "for-offline-installation"
	ForOfflineInstallationFlagUsage = "Creates a zip package that can be used for offline installation"

	K8sBinsFlagName  = "k8s-bins"
	K8sBinsFlagUsage = "Path to directory of locally built Kubernetes binaries (kubelet.exe, kube-proxy.exe, kubeadm.exe, kubectl.exe)"

	// Code signing flags
	CertificateFlagName = "certificate"
	CertificateFlagUsage = "Path to code signing certificate (.pfx file)"
	
	PasswordFlagName  = "password"
	PasswordFlagUsage = "Password for the code signing certificate"

	DeltaPackageFlagName  = "delta-package"
	DeltaPackageFlagUsage = "Creates a delta package for faster updates"

	PackageVersionFromFlagName  = "package-version-from"
	PackageVersionFromFlagUsage = "Path to the existing (base) full package .zip (required if --delta-package is set)"

	PackageVersionToFlagName  = "package-version-to"
	PackageVersionToFlagUsage = "Path to the new (target) full package .zip (required if --delta-package is set)"
)

func init() {
	PackageCmd.Flags().String(ControlPlaneCPUsFlagName, "", ControlPlaneCPUsFlagUsage)
	PackageCmd.Flags().String(ControlPlaneMemoryFlagName, "", ControlPlaneMemoryFlagUsage)
	PackageCmd.Flags().String(ControlPlaneDiskSizeFlagName, "", ControlPlaneDiskSizeFlagUsage)
	PackageCmd.Flags().StringP(ProxyFlagName, "p", "", ProxyFlagUsage)
	PackageCmd.Flags().StringP(TargetDirectoryFlagName, "d", "", TargetDirectoryFlagUsage)
	PackageCmd.Flags().StringP(ZipPackageFileNameFlagName, "n", "", ZipPackageFileNameFlagUsage)
	PackageCmd.Flags().Bool(ForOfflineInstallationFlagName, false, ForOfflineInstallationFlagUsage)
	PackageCmd.Flags().String(K8sBinsFlagName, "", K8sBinsFlagUsage)
	PackageCmd.Flags().Bool(DeltaPackageFlagName, false, DeltaPackageFlagUsage)
	PackageCmd.MarkFlagRequired(TargetDirectoryFlagName)
	PackageCmd.MarkFlagRequired(ZipPackageFileNameFlagName)

	PackageCmd.Flags().String(PackageVersionFromFlagName, "", PackageVersionFromFlagUsage)
	PackageCmd.Flags().String(PackageVersionToFlagName, "", PackageVersionToFlagUsage)
	PackageCmd.Flags().Lookup(PackageVersionFromFlagName).NoOptDefVal = ""
	PackageCmd.Flags().Lookup(PackageVersionToFlagName).NoOptDefVal = ""
	PackageCmd.Flags().Lookup(DeltaPackageFlagName).NoOptDefVal = "true"

	// NOTE: We do not mark the version flags as required here because they are only
	// required when --delta-package is set. Validation is handled in PreRunE below.
	PackageCmd.PreRunE = func(cmd *cobra.Command, args []string) error {
		delta, _ := cmd.Flags().GetBool(DeltaPackageFlagName)
		from, _ := cmd.Flags().GetString(PackageVersionFromFlagName)
		to, _ := cmd.Flags().GetString(PackageVersionToFlagName)
		if delta {
			if from == "" {
				return fmt.Errorf("--%s is required when --%s is set", PackageVersionFromFlagName, DeltaPackageFlagName)
			}	
			if to == "" {
				return fmt.Errorf("--%s is required when --%s is set", PackageVersionToFlagName, DeltaPackageFlagName)
			}
		} else {
			if from != "" {
				return fmt.Errorf("--%s can only be used when --%s is set", PackageVersionFromFlagName, DeltaPackageFlagName)
			}
			if to != "" {
				return fmt.Errorf("--%s can only be used when --%s is set", PackageVersionToFlagName, DeltaPackageFlagName)
			}
		}
		return nil
	}

	// Code signing flags
	PackageCmd.Flags().StringP(CertificateFlagName, "c", "", CertificateFlagUsage)
	PackageCmd.Flags().StringP(PasswordFlagName, "w", "", PasswordFlagUsage)
	
	PackageCmd.Flags().SortFlags = false
	PackageCmd.Flags().PrintDefaults()
}

func systemPackage(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	systemPackageCommand, params, err := buildSystemPackageCmd(cmd.Flags())
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", systemPackageCommand, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
	}
	if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' is installed on your system. Please uninstall '%s' first and try again.", runtimeConfig.InstallConfig().SetupName(), runtimeConfig.InstallConfig().SetupName()),
		}
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}

func buildSystemPackageCmd(flags *pflag.FlagSet) (string, []string, error) {
	flags.VisitAll(func(f *pflag.Flag) { slog.Debug("Param", "name", f.Name, "value", f.Value) })

	delta, _ := strconv.ParseBool(flags.Lookup(DeltaPackageFlagName).Value.String())

	// Shared params
	out, _ := strconv.ParseBool(flags.Lookup(common.OutputFlagName).Value.String())
	targetDir := flags.Lookup(TargetDirectoryFlagName).Value.String()
	zipName := flags.Lookup(ZipPackageFileNameFlagName).Value.String() // For delta this is the output delta zip

	params := []string{}
	if out { params = append(params, " -ShowLogs") }
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(zipName))

	// Code signing (applies to both normal and delta packages)
	certPath := flags.Lookup(CertificateFlagName).Value.String()
	password := flags.Lookup(PasswordFlagName).Value.String()
	if certPath != "" {
		if password == "" { return "", nil, fmt.Errorf("password is required when using a certificate") }
		params = append(params, " -CertificatePath "+utils.EscapeWithSingleQuotes(certPath))
		params = append(params, " -Password "+utils.EscapeWithSingleQuotes(password))
	} else if password != "" {
		return "", nil, fmt.Errorf("certificate is required when providing a password")
	}

	if delta {
		oldPkg := flags.Lookup(PackageVersionFromFlagName).Value.String()
		newPkg := flags.Lookup(PackageVersionToFlagName).Value.String()
		params = append(params, " -InputPackageOne "+utils.EscapeWithSingleQuotes(oldPkg))
		params = append(params, " -InputPackageTwo "+utils.EscapeWithSingleQuotes(newPkg))
		return utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "package", "New-K2sDeltaPackage.ps1")), params, nil
	}

	// Normal (full) package path
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1"))

	// Only add full-package specific params if not delta
	proxy := flags.Lookup(ProxyFlagName).Value.String(); if proxy != "" { params = append(params, " -Proxy "+proxy) }
	cpus := flags.Lookup(ControlPlaneCPUsFlagName).Value.String(); if cpus != "" { params = append(params, " -VMProcessorCount "+cpus) }
	memory := flags.Lookup(ControlPlaneMemoryFlagName).Value.String(); if memory != "" { params = append(params, " -VMMemoryStartupBytes "+memory) }
	disksize := flags.Lookup(ControlPlaneDiskSizeFlagName).Value.String(); if disksize != "" { params = append(params, " -VMDiskSize "+disksize) }
	forOfflineInstallation, _ := strconv.ParseBool(flags.Lookup(ForOfflineInstallationFlagName).Value.String()); if forOfflineInstallation { params = append(params, " -ForOfflineInstallation") }
	k8sBins := flags.Lookup(K8sBinsFlagName).Value.String(); if k8sBins != "" { params = append(params, fmt.Sprintf(" -K8sBinsPath '%s'", k8sBins)) }

	return systemPackageCommand, params, nil
}
