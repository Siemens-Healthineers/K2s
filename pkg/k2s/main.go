// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package main

import (
	"errors"
	"fmt"
	"k2s/cmd"
	"k2s/cmd/common"
	"k2s/utils/logging"
	"os"

	"github.com/pterm/pterm"
	"k8s.io/klog/v2"
)

func main() {
	defer logging.Finalize()

	if err := cmd.Execute(); err != nil {
		var cmdFailure *common.CmdFailure
		if errors.As(err, &cmdFailure) {
			if !cmdFailure.SuppressCliOutput {
				switch cmdFailure.Severity {
				case common.SeverityWarning:
					pterm.Warning.Println(cmdFailure.Message)
				case common.SeverityError:
					pterm.Error.Println(cmdFailure.Message)
				default:
					klog.Warning("no failure message provided")
				}
			}

			logging.DisableCliOutput()

			klog.InfoS("command failed",
				"severity", fmt.Sprintf("%d(%s)", cmdFailure.Severity, cmdFailure.Severity),
				"code", cmdFailure.Code,
				"message", cmdFailure.Message,
				"suppressCliOutput", cmdFailure.SuppressCliOutput)

			logging.Finalize()
			os.Exit(1)
		}

		pterm.Error.Println(err)
		logging.Exit(err)
	}
}
