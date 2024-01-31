// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	"k2s/utils"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var addExample = `
	# Add registry in K2s (enter credentials afterwards)
	k2s image registry add myregistry

	# Add registry with username and password in K2s 
	k2s image registry add myregistry -u testuser -p testpassword
`

var addCmd = &cobra.Command{
	Use:     "add",
	Short:   "Add container registry",
	RunE:    addRegistry,
	Example: addExample,
}

const (
	usernameLabel = "username"
	passwordLabel = "password"
)

func init() {
	includeAddCommand(addCmd)
}

func includeAddCommand(cmd *cobra.Command) {
	cmd.Flags().StringP(usernameLabel, "u", "", "username")
	cmd.Flags().StringP(passwordLabel, "p", "", "password")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func addRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry add <registry-name>'")
	}

	registryName := args[0]
	klog.V(4).Infof("Adding registry %s", registryName)
	pterm.Printfln("🤖 Adding %s to K2s cluster", registryName)

	addCmd, err := buildAddCmd(registryName, cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Add command : %s", addCmd)

	duration, err := utils.ExecutePowershellScript(addCmd)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, fmt.Sprintf("add registry %s", registryName))

	return nil
}

func buildAddCmd(registryName string, cmd *cobra.Command) (string, error) {
	addRegistryCmd := utils.FormatScriptFilePath(c.SetupRootDir + "\\" + "smallsetup" + "\\" + "helpers" + "\\" + "AddRegistry.ps1")

	if registryName == "" {
		return "", errors.New("registry name must not be empty")
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if outputFlag {
		addRegistryCmd += " -ShowLogs"
	}

	addRegistryCmd += " -RegistryName " + utils.EscapeWithSingleQuotes(registryName)

	username, err := cmd.Flags().GetString(usernameLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", usernameLabel)
	}

	addRegistryCmd += " -Username " + utils.EscapeWithSingleQuotes(username)

	password, err := cmd.Flags().GetString(passwordLabel)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s", passwordLabel)
	}

	addRegistryCmd += " -Password " + utils.EscapeWithSingleQuotes(password)

	return addRegistryCmd, nil
}
