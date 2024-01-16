// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package reset

import (
	"github.com/spf13/cobra"
)

var ResetCmd = &cobra.Command{
	Use:   "reset",
	Short: "Reset options",
}

func init() {
	ResetCmd.AddCommand(resetNetworkCmd)
	ResetCmd.AddCommand(resetSystemCmd)
}
