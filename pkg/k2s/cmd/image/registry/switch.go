// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	cd "k2s/config/defs"
	"k2s/utils"
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var switchExample = `
	# Login to configured registry 'myregistry' registry in K2s 
	k2s image registry switch myregistry
`

var switchCmd = &cobra.Command{
	Use:     "switch",
	Short:   "Switch to a configured registry",
	RunE:    switchRegistry,
	Example: switchExample,
}

func init() {
	includeSwitchCommand(switchCmd)
}

func includeSwitchCommand(cmd *cobra.Command) {
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func switchRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry switch <registry-name>'")
	}

	registryName := args[0]
	klog.V(4).Infof("Switching to registry %s", registryName)
	pterm.Printfln("🤖 Switching to registry %s", registryName)

	addCmd, err := buildSwitchCmd(registryName, cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Switch command : %s", addCmd)

	duration, err := utils.ExecutePowershellScript(addCmd)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, fmt.Sprintf("switch registry to %s", registryName))

	return nil
}

func buildSwitchCmd(registryName string, cmd *cobra.Command) (string, error) {
	switchRegistryCmd := utils.FormatScriptFilePath(c.SetupRootDir + "\\" + "smallsetup" + "\\" + "helpers" + "\\" + "SwitchRegistry.ps1")

	if registryName == "" {
		return "", errors.New("registry name must not be empty")
	}

	config := c.NewAccess()
	registries, err := config.GetConfiguredRegisties()
	if err != nil {
		return "", err
	}

	if len(registries) == 0 {
		return "", errors.New("no registries configured")
	}

	found := false
	for _, v := range registries {
		if v == cd.RegistryName(registryName) {
			found = true
		}
	}

	if !found {
		return "", fmt.Errorf("registry '%s' not configured", registryName)
	}

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	if outputFlag {
		switchRegistryCmd += " -ShowLogs"
	}

	switchRegistryCmd += " -RegistryName " + registryName

	return switchRegistryCmd, nil
}
