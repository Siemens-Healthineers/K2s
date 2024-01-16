//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package cmd

import (
	"flag"
	"strconv"

	"devgon/cmd/install"
	"devgon/cmd/remove"
	"devgon/cmd/version"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var (
	devgoneCmd = &cobra.Command{
		Use:   "devgon",
		Short: "devgon – command-line tool to replace Microsoft's devcon.exe",
		Long:  ``,

		SilenceErrors: true,
		SilenceUsage:  true,
	}
)

func Execute() error {
	return devgoneCmd.Execute()
}

func init() {
	klog.InitFlags(nil)

	verbose := 0
	devgoneCmd.PersistentPreRun = func(cmd *cobra.Command, args []string) {
		_ = flag.Set("v", strconv.Itoa(verbose))
	}

	cobra.OnInitialize()
	devgoneCmd.CompletionOptions.DisableDefaultCmd = true
	devgoneCmd.AddCommand(install.InstallDeviceCmd)
	devgoneCmd.AddCommand(remove.RemoveDeviceCmd)
	devgoneCmd.AddCommand(version.VersionCmd)

	devgoneCmd.PersistentFlags().IntVarP(&verbose, "v", "v", 0, "number for the log level verbosity, e.g --v=8")
}
