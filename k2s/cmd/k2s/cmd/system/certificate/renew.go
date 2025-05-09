// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package certificate

import (
	"path/filepath"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

var renewCmd = &cobra.Command{
	Use:   "renew",
	Short: "Renews Kubernetes certificates",
	Long: `
Determines if Kubernetes certificates have expired and renews them.
With the --force option, the certificate renewal is performed irrespective of their expiration status.
`,
	RunE: renewCertificates,
}

func init() {
	renewCmd.Flags().BoolP("force", "f", false, "force renewal of certificates")
	renewCmd.Flags().SortFlags = false
	renewCmd.Flags().PrintDefaults()
}

func renewCertificates(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	pterm.Println("🔑 Renewing Kubernetes certificates...")

	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "certificate", "renew.ps1"))
	params := []string{}

	force, err := strconv.ParseBool(cmd.Flags().Lookup("force").Value.String())
	if err != nil {
		return err
	}
	if force {
		params = append(params, "-Force")
	}

	showLogs, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return err
	}
	if showLogs {
		params = append(params, "-ShowLogs")
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}
