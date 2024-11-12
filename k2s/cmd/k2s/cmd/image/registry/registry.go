// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
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
	Cmd.AddCommand(listCmd)
}
