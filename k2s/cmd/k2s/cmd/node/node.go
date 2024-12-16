// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/add"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/connect"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/copy"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/exec"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/node/remove"
	"github.com/spf13/cobra"
)

func NewCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "node",
		Short: "Manage cluster nodes",
	}
	cmd.AddCommand(add.NewCmd())
	cmd.AddCommand(remove.NewCmd())
	cmd.AddCommand(copy.NewCmd())
	cmd.AddCommand(exec.NewCmd())
	cmd.AddCommand(connect.NewCmd())

	return cmd
}
