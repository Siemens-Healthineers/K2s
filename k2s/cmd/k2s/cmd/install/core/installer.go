// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core

import (
	"fmt"
	"log/slog"
	"time"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	Printfln(format string, m ...any)
}

type Installer struct {
	InstallConfigAccess       InstallConfigAccess
	Printer                   Printer
	ExecutePsScript           func(cmd string, psVersion powershell.PowerShellVersion) (time.Duration, error)
	GetVersionFunc            func() version.Version
	GetPlatformFunc           func() string
	GetInstallDirFunc         func() string
	PrintCompletedMessageFunc func(duration time.Duration, command string)
	LoadConfigFunc            func(configDir string) (*setupinfo.Config, error)
}

func (i *Installer) Install(
	kind ic.Kind,
	ccmd *cobra.Command,
	buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error {
	configDir := ccmd.Context().Value(common.ContextKeyConfigDir).(string)
	setupConfig, err := i.LoadConfigFunc(configDir)
	if err == nil && setupConfig.SetupName != "" {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", setupConfig.SetupName),
		}
	}

	config, err := i.InstallConfigAccess.Load(kind, ccmd.Flags())
	if err != nil {
		return err
	}

	slog.Debug("Installing using config", "config", config)

	cmd, err := buildCmdFunc(config)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", cmd)

	psVersion := powershell.DefaultPsVersions
	if kind == ic.MultivmConfigType && !config.LinuxOnly {
		psVersion = powershell.PowerShellV7
	}

	i.Printer.Printfln("🤖 Installing K2s '%s' %s in '%s' on %s using PowerShell %s", kind, i.GetVersionFunc(), i.GetInstallDirFunc(), i.GetPlatformFunc(), psVersion)

	duration, err := i.ExecutePsScript(cmd, psVersion)
	if err != nil {
		return err
	}

	i.PrintCompletedMessageFunc(duration, fmt.Sprintf("%s installation", kind))

	return nil
}
