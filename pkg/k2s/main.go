// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"k2s/cmd"
	"k2s/cmd/common"
	"k2s/setupinfo"
	"k2s/status"
	"k2s/utils/logging"
	"os"

	"github.com/pterm/pterm"
	"k8s.io/klog/v2"
)

func main() {
	defer logging.Finalize()

	if err := cmd.Execute(); err != nil {
		if errors.Is(err, common.ErrSilent) {
			logging.DisableCliOutput()
			klog.Infof("Silent error occurred: %v", err)
			logging.Finalize()
			os.Exit(1)
		}
		var pcnmErr *common.PreConditionNotMetError
		if errors.As(err, &pcnmErr) {
			pterm.Warning.Println(pcnmErr.Message)
			logging.DisableCliOutput()
			klog.InfoS("precondition not met", "code", pcnmErr.Code, "message", pcnmErr.Message)
			logging.Finalize()
			os.Exit(1)
		}

		if errors.Is(err, setupinfo.ErrNotInstalled) {
			pterm.Info.Println("You have not installed K2s setup yet, please start the installation with command 'k2s.exe install' first")
		} else if errors.Is(err, status.ErrNotRunning) {
			pterm.Info.Println("K2s is not running. To interact with the system, please start it with 'k2s start' first")
		} else if errors.Is(err, status.ErrRunning) {
			pterm.Info.Println("K2s is still running. Please stop it with 'k2s stop' first")
		} else {
			pterm.Error.Println(err)
		}

		logging.Exit(err)
	}
}
