// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addonimport

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/setupinfo"
	"k2s/utils"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var importCommandExample = `
  # Import addon 'ingress-nginx' and 'traefik' from an exported tar archive
  k2s addons import ingress-nginx traefik -z C:\tmp\addons.zip

  # Import all addons from an exported tar archive
  k2s addons import -z C:\tmp\addons.zip
`

const (
	zipLabel   = "zip"
	defaultZip = ""
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "import ADDON",
		Short:   "Import an addon from a zip file",
		Example: importCommandExample,
		RunE:    importImage,
	}

	cmd.Flags().StringP(zipLabel, "z", defaultZip, "zip archive of exported addon")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func importImage(cmd *cobra.Command, args []string) error {
	importCmd, err := buildImportCmd(cmd, args)
	if err != nil {
		return err
	}

	klog.V(3).Infof("import command : %s", importCmd)

	duration, err := utils.ExecutePowershellScript(importCmd)
	switch err {
	case nil:
		break
	case setupinfo.ErrNotInstalled:
		common.PrintNotInstalledMessage()
		return nil
	default:
		return err
	}

	common.PrintCompletedMessage(duration, "addons import")

	return nil
}

func buildImportCmd(ccmd *cobra.Command, addons []string) (string, error) {
	importCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\addons\\Import.ps1")

	if len(addons) > 0 {
		names := ""
		for _, addon := range addons {
			names += utils.EscapeWithSingleQuotes(addon) + ","
		}
		names = names[:len(names)-1]

		importCommand += " -Names " + names
	}

	imagePath, err := ccmd.Flags().GetString(zipLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", zipLabel)
	}
	if imagePath == "" {
		return "", errors.New("no path to tar archive provided")
	}

	importCommand += " -Zipfile " + utils.EscapeWithSingleQuotes(imagePath)

	outputFlag, err := strconv.ParseBool(ccmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if outputFlag {
		importCommand += " -ShowLogs"
	}

	return importCommand, nil
}
