// SPDX-FileCopyrightText:  © 2024 The K2s Authors
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
	Cmd.AddCommand(listCmd)
}
