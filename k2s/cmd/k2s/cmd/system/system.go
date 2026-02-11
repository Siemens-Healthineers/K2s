// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package system

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/certificate"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/dump"
	systempackage "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/package"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/proxy"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/system/reset"
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
	SystemCmd.AddCommand(upgrade.UpgradeCmd)
	SystemCmd.AddCommand(reset.ResetCmd)
	SystemCmd.AddCommand(systempackage.PackageCmd)
	SystemCmd.AddCommand(users.NewCommand())
	SystemCmd.AddCommand(certificate.CertificateCmd)
	SystemCmd.AddCommand(proxy.ProxyCmd)
}
