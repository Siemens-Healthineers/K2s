// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"github.com/spf13/cobra"
)

var SshCmd = &cobra.Command{
	Use:        "ssh",
	Short:      "Connects via SSH to a specific K8s node",
	Deprecated: "This command is deprecated and will be removed in the future. Use 'k2s node connect' or 'k2s node exec' instead.",
}

func init() {
	SshCmd.AddCommand(sshMasterCmd)
}
