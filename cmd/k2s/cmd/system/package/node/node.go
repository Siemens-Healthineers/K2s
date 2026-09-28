// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

// Package nodepackage implements the --node-package flag logic for
// 'k2s system package'. It owns all constants, validation and PS command
// construction related to building a Linux node artifact zip.
package nodepackage

import (
	"fmt"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

const (
	NodePackageFlagName  = "node-package"
	NodePackageFlagUsage = "Creates a zip package containing Linux node packages (kubelet, kubeadm, kubectl, CRI-O, buildah) for the specified OS and version; requires an existing K2s cluster and --proxy http://172.19.1.1:8181"

	OSFlagName  = "os"
	OSFlagUsage = "Target Linux distribution and version combined (e.g. debian12, debian13, ubuntu26)"

	ArchitectureFlagName  = "architecture"
	ArchitectureFlagUsage = "Target CPU architecture for the node package cloud image for Ubuntu 26 only (amd64 or arm64). Defaults to amd64. Other OS variants currently do not support architecture selection."
	ArchitectureDefault   = "amd64"

	IncludeGpuFlagName  = "include-gpu"
	IncludeGpuFlagUsage = "Include NVIDIA Container Toolkit packages for GPU support. When 'k2s node add' uses a package built with this flag, it automatically detects if the target node has an NVIDIA GPU and configures GPU support (installs container toolkit, configures CRI-O, labels the node)."

	DeltaPackageFlagName       = "delta-package"
	PackageVersionFromFlagName = "package-version-from"
	PackageVersionToFlagName   = "package-version-to"
)

// SupportedArchitectures lists the CPU architectures accepted by --architecture.
var SupportedArchitectures = []string{"amd64", "arm64"}

// RegisterFlags registers the node-package specific flags on the given command.
func RegisterFlags(cmd *cobra.Command) {
	cmd.Flags().Bool(NodePackageFlagName, false, NodePackageFlagUsage)
	cmd.Flags().String(OSFlagName, "", OSFlagUsage)
	cmd.Flags().String(ArchitectureFlagName, ArchitectureDefault, ArchitectureFlagUsage)
	cmd.Flags().Bool(IncludeGpuFlagName, false, IncludeGpuFlagUsage)
}

// IsSet returns true when the --node-package flag is present and enabled.
func IsSet(flags *pflag.FlagSet) bool {
	v, _ := flags.GetBool(NodePackageFlagName)
	return v
}

// isSupportedArchitecture returns true when arch is an accepted --architecture value.
func isSupportedArchitecture(arch string) bool {
	for _, a := range SupportedArchitectures {
		if a == arch {
			return true
		}
	}
	return false
}

// Validate checks that --os is provided and is in the supported list when --node-package is set.
// supportedOS is the list read from cfg/config.json (supportedWorkerOS[].os).
func Validate(flags *pflag.FlagSet, supportedOS []string) error {
	deltaRequested, _ := flags.GetBool(DeltaPackageFlagName)

	if deltaRequested {
		return validateDelta(flags, supportedOS)
	}

	if arch, _ := flags.GetString(ArchitectureFlagName); arch != "" && !isSupportedArchitecture(arch) {
		return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", ArchitectureFlagName, arch, strings.Join(SupportedArchitectures, ", "))
	}

	os, _ := flags.GetString(OSFlagName)
	if os == "" {
		return fmt.Errorf("--%s is required when --%s is set", OSFlagName, NodePackageFlagName)
	}
	if !isSupportedOS(os, supportedOS) {
		return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", OSFlagName, os, strings.Join(supportedOS, ", "))
	}
	return nil
}

// validateDelta validates the flags for node-delta package creation.
func validateDelta(flags *pflag.FlagSet, supportedOS []string) error {
	from, _ := flags.GetString(PackageVersionFromFlagName)
	to, _ := flags.GetString(PackageVersionToFlagName)
	if from == "" {
		return fmt.Errorf("--%s is required when --%s and --%s are set", PackageVersionFromFlagName, NodePackageFlagName, DeltaPackageFlagName)
	}
	if to == "" {
		return fmt.Errorf("--%s is required when --%s and --%s are set", PackageVersionToFlagName, NodePackageFlagName, DeltaPackageFlagName)
	}

	os, _ := flags.GetString(OSFlagName)
	if os == "" {
		return nil
	}
	if !isSupportedOS(os, supportedOS) {
		return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", OSFlagName, os, strings.Join(supportedOS, ", "))
	}
	return nil
}

// isSupportedOS reports whether os is present in the supportedOS list.
func isSupportedOS(os string, supportedOS []string) bool {
	for _, s := range supportedOS {
		if s == os {
			return true
		}
	}
	return false
}

// BuildCmd constructs the PowerShell script path and parameters for node package creation.
// targetDir and zipName are required; an error is returned if either is empty.
func BuildCmd(flags *pflag.FlagSet, out bool, targetDir, zipName, proxy string) (string, []string, error) {
	if targetDir == "" {
		return "", nil, fmt.Errorf("required flag(s) \"target-dir\" not set")
	}
	if zipName == "" {
		return "", nil, fmt.Errorf("required flag(s) \"name\" not set")
	}

	os := flags.Lookup(OSFlagName).Value.String()
	deltaRequested, _ := flags.GetBool(DeltaPackageFlagName)

	params := []string{}
	if out {
		params = append(params, " -ShowLogs")
	}
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(zipName))

	if deltaRequested {
		from := flags.Lookup(PackageVersionFromFlagName).Value.String()
		to := flags.Lookup(PackageVersionToFlagName).Value.String()
		if from == "" {
			return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", PackageVersionFromFlagName)
		}
		if to == "" {
			return "", nil, fmt.Errorf("required flag(s) \"%s\" not set", PackageVersionToFlagName)
		}
		params = append(params, " -InputPackageOne "+utils.EscapeWithSingleQuotes(from))
		params = append(params, " -InputPackageTwo "+utils.EscapeWithSingleQuotes(to))
		if os != "" {
			params = append(params, " -OS "+utils.EscapeWithSingleQuotes(os))
		}

		scriptPath := utils.FormatScriptFilePath(
			filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sNodeDeltaPackage.ps1"),
		)
		return scriptPath, params, nil
	}

	params = append(params, " -OS "+utils.EscapeWithSingleQuotes(os))
	if proxy != "" {
		params = append(params, " -Proxy "+proxy)
	}

	arch := flags.Lookup(ArchitectureFlagName).Value.String()
	if arch == "" {
		arch = ArchitectureDefault
	}
	params = append(params, " -Architecture "+utils.EscapeWithSingleQuotes(arch))

	includeGpu, _ := flags.GetBool(IncludeGpuFlagName)
	if includeGpu {
		params = append(params, " -IncludeGpu")
	}

	scriptPath := utils.FormatScriptFilePath(
		filepath.Join(utils.InstallDir(), "lib", "scripts", "windows", "host", "system", "package", "New-K2sNodePackage.ps1"),
	)
	return scriptPath, params, nil
}
