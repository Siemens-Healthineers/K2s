// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"github.com/spf13/cobra"
)

var Cmd = &cobra.Command{
	Use:   "registry",
	Short: "registry options",
}

func init() {
	Cmd.AddCommand(addCmd)
	Cmd.AddCommand(rmCmd)
	Cmd.AddCommand(updateCmd)
	Cmd.AddCommand(listCmd)
}
