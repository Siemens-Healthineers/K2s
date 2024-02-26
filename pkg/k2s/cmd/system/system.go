// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package system

import (
	"k2s/cmd/system/dump"
	systempackage "k2s/cmd/system/package"
	"k2s/cmd/system/reset"
	"k2s/cmd/system/scp"
	"k2s/cmd/system/ssh"
	"k2s/cmd/system/upgrade"

	"github.com/spf13/cobra"
)

var SystemCmd = &cobra.Command{
	Use:   "system",
	Short: "Performs system-related tasks",
}

func init() {
	SystemCmd.AddCommand(dump.DumpCmd)
	SystemCmd.AddCommand(ssh.SshCmd)
	SystemCmd.AddCommand(scp.ScpCmd)
	SystemCmd.AddCommand(upgrade.UpgradeCmd)
	SystemCmd.AddCommand(reset.ResetCmd)
	SystemCmd.AddCommand(systempackage.PackageCmd)
}
