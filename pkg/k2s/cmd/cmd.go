// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cmd

import (
	"k2s/cmd/addons"
	"k2s/cmd/common"
	cm "k2s/cmd/common"
	im "k2s/cmd/image"
	in "k2s/cmd/install"
	"k2s/cmd/start"
	stat "k2s/cmd/status"
	stop "k2s/cmd/stop"
	sys "k2s/cmd/system"
	un "k2s/cmd/uninstall"
	ve "k2s/cmd/version"

	"k2s/cmd/params"
	"k2s/utils/logging"

	"github.com/spf13/cobra"
)

var (
	rootCmd = &cobra.Command{
		Use:           cm.CliName,
		Short:         "k2s – command-line tool to interact with the K2s cluster",
		SilenceErrors: true,
		SilenceUsage:  true,
	}
)

func Execute() error {
	return rootCmd.Execute()
}

func init() {
	logging.Initialize(common.LogFilePath())

	rootCmd.CompletionOptions.DisableDefaultCmd = true

	rootCmd.AddCommand(start.Startk8sCmd)
	rootCmd.AddCommand(stop.Stopk8sCmd)
	rootCmd.AddCommand(in.InstallCmd)
	rootCmd.AddCommand(un.Uninstallk8sCmd)
	rootCmd.AddCommand(im.ImageCmd)
	rootCmd.AddCommand(stat.StatusCmd)
	rootCmd.AddCommand(addons.NewCmd())
	rootCmd.AddCommand(ve.VersionCmd)
	rootCmd.AddCommand(sys.SystemCmd)

	rootCmd.PersistentFlags().BoolP(params.OutputFlagName, params.OutputFlagShorthand, false, params.OutputFlagUsage)
	verbosityLevel := rootCmd.PersistentFlags().IntP(params.VerbosityFlagName, params.VerbosityFlagShorthand, 0, params.VerbosityFlagUsage)

	rootCmd.PersistentPreRun = func(cmd *cobra.Command, args []string) {
		// glue code to set verbosity level extracted from CLI via "pflag" package in klog using "flag" package
		// flag parsing is done when cobra command gets executed; as a result the CLI flag values are not available beforehand, e.g. in init() functions
		logging.SetVerbosity(*verbosityLevel)
	}
}
