// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package certificate

import "github.com/spf13/cobra"

var CertificateCmd = &cobra.Command{
	Use:   "certificate",
	Short: "Manage system certificates",
}

func init() {
	CertificateCmd.AddCommand(renewCmd)
}
