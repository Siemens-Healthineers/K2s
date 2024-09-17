// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core

import (
	"errors"
	"fmt"
	"log/slog"
	"time"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	Printfln(format string, m ...any)
	PrintWarning(m ...any)
}

type Installer struct {
	InstallConfigAccess       InstallConfigAccess
	Printer                   Printer
	ExecutePsScript           func(script string, psVersion powershell.PowerShellVersion, writer os.StdWriter) error
	GetVersionFunc            func() version.Version
	GetPlatformFunc           func() string
	GetInstallDirFunc         func() string
	PrintCompletedMessageFunc func(duration time.Duration, command string)
	LoadConfigFunc            func(configDir string) (*setupinfo.Config, error)
	SetConfigFunc             func(configDir string, config *setupinfo.Config) error
	DeleteConfigFunc          func(configDir string) error
}

func (i *Installer) Install(
	kind ic.Kind,
	ccmd *cobra.Command,
	buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error {
	context := ccmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	configDir := context.Config().Host.K2sConfigDir
	setupConfig, err := i.LoadConfigFunc(configDir)
	if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
		return common.CreateSystemInCorruptedStateCmdFailure()
	}
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

	outputWriter := common.NewPtermWriter()

	start := time.Now()

	err = i.ExecutePsScript(cmd, psVersion, outputWriter)
	if err != nil {
		// Check for pre-requisites first
		errorLine, found := common.GetInstallPreRequisiteError(outputWriter.ErrorLines)
		if found {
			i.Printer.PrintWarning("Prerequisite check failed,", errorLine)
			i.Printer.PrintWarning("Have a look at the pre-requisites 'https://github.com/Siemens-Healthineers/K2s/blob/main/docs/op-manual/installing-k2s.md#prerequisites' and re-issue 'k2s install'")
			err = i.DeleteConfigFunc(configDir)
			if err != nil {
				slog.Debug("config file does not exist, nothing to do")
			}
			return nil
		}

		if outputWriter.ErrorOccurred {
			// corrupted state
			setupConfig, err := i.LoadConfigFunc(configDir)
			if err != nil {
				if setupConfig == nil {
					setupConfig = &setupinfo.Config{
						Corrupted: true,
					}
					i.SetConfigFunc(configDir, setupConfig)
				}
			} else {
				setupConfig.Corrupted = true
				i.SetConfigFunc(configDir, setupConfig)
			}

			return common.CreateSystemInCorruptedStateCmdFailure()
		}

		return err
	}

	duration := time.Since(start)
	i.PrintCompletedMessageFunc(duration, fmt.Sprintf("%s installation", kind))

	return nil
}
