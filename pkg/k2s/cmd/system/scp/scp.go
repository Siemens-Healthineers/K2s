// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package scp

import (
	"github.com/spf13/cobra"
)

var ScpCmd = &cobra.Command{
	Use:   "scp",
	Short: "Copies sources via scp from/to a specific VM",
}

func init() {
	ScpCmd.AddCommand(scpMasterCmd)
	ScpCmd.AddCommand(scpWorkerCmd)
}
