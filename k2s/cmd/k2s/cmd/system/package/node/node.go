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
	NodePackageFlagUsage = "Creates a zip package containing Linux node packages (kubelet, kubeadm, kubectl, CRI-O, buildah) for the specified OS and version"

	OSFlagName  = "os"
	OSFlagUsage = "Target Linux distribution and version combined (e.g. debian12, debian13)"
)

// RegisterFlags registers the node-package specific flags on the given command.
func RegisterFlags(cmd *cobra.Command) {
	cmd.Flags().Bool(NodePackageFlagName, false, NodePackageFlagUsage)
	cmd.Flags().String(OSFlagName, "", OSFlagUsage)
}

// IsSet returns true when the --node-package flag is present and enabled.
func IsSet(flags *pflag.FlagSet) bool {
	v, _ := flags.GetBool(NodePackageFlagName)
	return v
}

// Validate checks that --os is provided and is in the supported list when --node-package is set.
// supportedOS is the list read from cfg/config.json (supportedWorkerOS[].os).
func Validate(flags *pflag.FlagSet, supportedOS []string) error {
	os, _ := flags.GetString(OSFlagName)
	if os == "" {
		return fmt.Errorf("--%s is required when --%s is set", OSFlagName, NodePackageFlagName)
	}
	for _, s := range supportedOS {
		if s == os {
			return nil
		}
	}
	return fmt.Errorf("--%s value '%s' is not supported. Supported: %s", OSFlagName, os, strings.Join(supportedOS, ", "))
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

	params := []string{}
	if out {
		params = append(params, " -ShowLogs")
	}
	params = append(params, " -OS "+utils.EscapeWithSingleQuotes(os))
	params = append(params, " -TargetDirectory "+utils.EscapeWithSingleQuotes(targetDir))
	params = append(params, " -ZipPackageFileName "+utils.EscapeWithSingleQuotes(zipName))
	if proxy != "" {
		params = append(params, " -Proxy "+proxy)
	}

	scriptPath := utils.FormatScriptFilePath(
		filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "package", "New-K2sNodePackage.ps1"),
	)
	return scriptPath, params, nil
}
