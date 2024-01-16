// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core

import (
	"fmt"
	ic "k2s/cmd/install/config"
	cd "k2s/config/defs"
	"time"

	"k8s.io/klog/v2"

	"base/version"
	"k2s/utils"

	"github.com/spf13/pflag"
)

type ConfigAccess interface {
	GetSetupType() (cd.SetupType, error)
}

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	PrintInfofln(format string, m ...any)
	Printfln(format string, m ...any)
}

type PsExecutor interface {
	ExecutePowershellScript(cmd string, psVersion utils.PowerShellVersion) (time.Duration, error)
}

type installer struct {
	configAccess              ConfigAccess
	installConfigAccess       InstallConfigAccess
	printer                   Printer
	executor                  PsExecutor
	getVersionFunc            func() version.Version
	getPlatformFunc           func() string
	getInstallDirFunc         func() string
	printCompletedMessageFunc func(duration time.Duration, command string)
}

func NewInstaller(configAccess ConfigAccess,
	printer Printer,
	installConfigAccess InstallConfigAccess,
	executor PsExecutor,
	getVersionFunc func() version.Version,
	getPlatformFunc func() string,
	getInstallDirFunc func() string,
	printCompletedMessageFunc func(duration time.Duration, command string)) *installer {
	return &installer{
		configAccess:              configAccess,
		printer:                   printer,
		installConfigAccess:       installConfigAccess,
		executor:                  executor,
		getVersionFunc:            getVersionFunc,
		getPlatformFunc:           getPlatformFunc,
		getInstallDirFunc:         getInstallDirFunc,
		printCompletedMessageFunc: printCompletedMessageFunc,
	}
}

func (i *installer) Install(kind ic.Kind, flags *pflag.FlagSet, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error)) error {
	setupType, err := i.configAccess.GetSetupType()
	if err == nil && setupType != "" {
		i.printer.PrintInfofln("'%s' setup type already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards.", setupType)
		return nil
	}

	config, err := i.installConfigAccess.Load(kind, flags)
	if err != nil {
		return err
	}

	klog.V(4).Infof("Using config: %v", config)

	cmd, err := buildCmdFunc(config)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Install command: %s", cmd)

	psVersion := utils.PowerShellV5
	if kind == ic.MultivmConfigType && !config.LinuxOnly {
		psVersion = utils.PowerShellV7
	}

	i.printer.Printfln("🤖 Installing K2s '%s' %s in '%s' on %s using PowerShell %s", kind, i.getVersionFunc(), i.getInstallDirFunc(), i.getPlatformFunc(), psVersion)

	duration, err := i.executor.ExecutePowershellScript(cmd, psVersion)
	if err != nil {
		return err
	}

	i.printCompletedMessageFunc(duration, fmt.Sprintf("%s installation", kind))

	return nil
}
