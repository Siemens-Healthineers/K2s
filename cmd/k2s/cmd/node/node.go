// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node

import (
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/add"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/connect"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/copy"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/exec"
	"github.com/k2s-project/k2s/cmd/k2s/cmd/node/remove"
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
