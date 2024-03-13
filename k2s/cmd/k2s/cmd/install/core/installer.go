// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core

import (
	"fmt"
	"log/slog"
	"time"

	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/cmd/k2s/setupinfo"

	"github.com/siemens-healthineers/k2s/internal/version"

	"github.com/spf13/pflag"
)

type ConfigAccess interface {
	GetSetupName() (setupinfo.SetupName, error)
}

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	Printfln(format string, m ...any)
}

type installer struct {
	configAccess              ConfigAccess
	installConfigAccess       InstallConfigAccess
	printer                   Printer
	executePsScript           func(cmd string, options ...psexecutor.ExecOptions) (time.Duration, error)
	getVersionFunc            func() version.Version
	getPlatformFunc           func() string
	getInstallDirFunc         func() string
	printCompletedMessageFunc func(duration time.Duration, command string)
}

func NewInstaller(configAccess ConfigAccess,
	printer Printer,
	installConfigAccess InstallConfigAccess,
	executePsScript func(cmd string, options ...psexecutor.ExecOptions) (time.Duration, error),
	getVersionFunc func() version.Version,
	getPlatformFunc func() string,
	getInstallDirFunc func() string,
	printCompletedMessageFunc func(duration time.Duration, command string)) *installer {
	return &installer{
		configAccess:              configAccess,
		printer:                   printer,
		installConfigAccess:       installConfigAccess,
		executePsScript:           executePsScript,
		getVersionFunc:            getVersionFunc,
		getPlatformFunc:           getPlatformFunc,
		getInstallDirFunc:         getInstallDirFunc,
		printCompletedMessageFunc: printCompletedMessageFunc,
	}
}

func (i *installer) Install(kind ic.Kind, flags *pflag.FlagSet, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error {
	setupName, err := i.configAccess.GetSetupName()
	if err == nil && setupName != "" {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "system-already-installed",
			Message:  fmt.Sprintf("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", setupName),
		}
	}

	config, err := i.installConfigAccess.Load(kind, flags)
	if err != nil {
		return err
	}

	slog.Debug("Installing using config", "config", config)

	cmd, err := buildCmdFunc(config)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", cmd)

	psVersion := psexecutor.PowerShellV5
	if kind == ic.MultivmConfigType && !config.LinuxOnly {
		psVersion = psexecutor.PowerShellV7
	}

	i.printer.Printfln("🤖 Installing K2s '%s' %s in '%s' on %s using PowerShell %s", kind, i.getVersionFunc(), i.getInstallDirFunc(), i.getPlatformFunc(), psVersion)

	duration, err := i.executePsScript(cmd, psexecutor.ExecOptions{PowerShellVersion: psVersion})
	if err != nil {
		return err
	}

	i.printCompletedMessageFunc(duration, fmt.Sprintf("%s installation", kind))

	return nil
}
