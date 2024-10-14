// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"github.com/spf13/cobra"
)

var SshCmd = &cobra.Command{
	Use:   "ssh",
	Short: "Connects via SSH to a specific K8s node",
}

func init() {
	SshCmd.AddCommand(sshMasterCmd)
	SshCmd.AddCommand(sshWorkerCmd)
}
