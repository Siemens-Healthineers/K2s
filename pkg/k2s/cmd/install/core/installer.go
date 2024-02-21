// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package core

import (
	"fmt"
	"k2s/cmd/common"
	ic "k2s/cmd/install/config"
	"k2s/setupinfo"
	"k2s/utils/psexecutor"
	"time"

	"k8s.io/klog/v2"

	"base/version"

	"github.com/spf13/pflag"
)

type ConfigAccess interface {
	GetSetupName() (setupinfo.SetupName, error)
}

type InstallConfigAccess interface {
	Load(kind ic.Kind, cmdFlags *pflag.FlagSet) (*ic.InstallConfig, error)
}

type Printer interface {
	PrintInfofln(format string, m ...any)
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
		i.printer.PrintInfofln("'%s' setup already installed, please uninstall with 'k2s uninstall' first and re-run the install command afterwards", setupName)
		return common.ErrSilent
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
