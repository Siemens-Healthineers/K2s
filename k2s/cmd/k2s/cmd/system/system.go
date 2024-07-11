// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package system

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/dump"
	systempackage "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/package"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/proxy"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/reset"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/scp"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/ssh"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/upgrade"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/users"

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
	SystemCmd.AddCommand(proxy.ProxyCmd)
	SystemCmd.AddCommand(users.NewCommand())
}
