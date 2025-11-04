// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package core

import (
	"errors"
	"fmt"
	"log/slog"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/os"
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
	InstallConfigAccess      InstallConfigAccess
	Printer                  Printer
	ExecutePsScript          func(script string, writer os.StdWriter) error
	GetVersionFunc           func() version.Version
	GetPlatformFunc          func() string
	GetInstallDirFunc        func() string
	LoadConfigFunc           func(configDir string) (*config.K2sRuntimeConfig, error)
	MarkSetupAsCorruptedFunc func(configDir string) error
	DeleteConfigFunc         func(configDir string) error
}

func (i *Installer) Install(
	kind ic.Kind,
	ccmd *cobra.Command,
	buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error),
	cmdSession cc.CmdSession) error {
	context := ccmd.Context().Value(cc.ContextKeyCmdContext).(*cc.CmdContext)
	configDir := context.Config().Host().K2sSetupConfigDir()

	runtimeConfig, err := i.LoadConfigFunc(configDir)

	if errors.Is(err, config.ErrSystemInCorruptedState) {
		return cc.CreateSystemInCorruptedStateCmdFailure()
	}
	if err != nil && !errors.Is(err, config.ErrSystemNotInstalled) {
		return err
	}
	if err == nil && runtimeConfig.InstallConfig().SetupName() != "" {
		return &cc.CmdFailure{
			Severity: cc.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", runtimeConfig.InstallConfig().SetupName()),
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

	i.Printer.Printfln("🤖 Installing K2s '%s' %s in '%s' on %s", kind, i.GetVersionFunc(), i.GetInstallDirFunc(), i.GetPlatformFunc())

	outputWriter := cc.NewPtermWriter()

	err = i.ExecutePsScript(cmd, outputWriter)
	if err != nil {
		// Check for pre-requisites first
		errorLine, found := cc.GetInstallPreRequisiteError(outputWriter.ErrorLines)
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
			if err := i.MarkSetupAsCorruptedFunc(configDir); err != nil {
				return fmt.Errorf("error while marking setup as corrupted: %w", err)
			}
			return cc.CreateSystemInCorruptedStateCmdFailure()
		}
		return err
	}

	cmdSession.Finish()

	return nil
}
