// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

var (
	switchExample = `
	# Login to configured registry 'myregistry' registry in K2s 
	k2s image registry switch myregistry
`

	switchCmd = &cobra.Command{
		Use:     "switch",
		Short:   "Switch to a configured registry",
		RunE:    switchRegistry,
		Example: switchExample,
	}
)

func init() {
	switchCmd.Flags().SortFlags = false
	switchCmd.Flags().PrintDefaults()
}

func switchRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry switch <registry-name>'")
	}

	registryName := args[0]

	klog.V(4).Infof("Switching to registry '%s'", registryName)

	pterm.Printfln("🤖 Switching to registry '%s'", registryName)

	psCmd, params, err := buildSwitchPsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Error != nil {
		return cmdResult.Error.ToError()
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image registry switch")

	return nil
}

func buildSwitchPsCmd(registryName string, cmd *cobra.Command) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\helpers\\SwitchRegistry.ps1")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	params = append(params, " -RegistryName "+registryName)

	return
}
