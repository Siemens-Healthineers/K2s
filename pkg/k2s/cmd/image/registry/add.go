// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"k2s/cmd/common"
	p "k2s/cmd/params"
	c "k2s/config"
	"k2s/setupinfo"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
)

const (
	usernameFlag = "username"
	passwordFlag = "password"
)

var (
	addExample = `
	# Add registry in K2s (enter credentials afterwards)
	k2s image registry add myregistry

	# Add registry with username and password in K2s 
	k2s image registry add myregistry -u testuser -p testpassword
`

	addCmd = &cobra.Command{
		Use:     "add",
		Short:   "Add container registry",
		RunE:    addRegistry,
		Example: addExample,
	}
)

func init() {
	addCmd.Flags().StringP(usernameFlag, "u", "", usernameFlag)
	addCmd.Flags().StringP(passwordFlag, "p", "", passwordFlag)
	addCmd.Flags().SortFlags = false
	addCmd.Flags().PrintDefaults()
}

func addRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry add <registry-name>'")
	}

	registryName := args[0]

	klog.V(4).Infof("Adding registry '%s'", registryName)

	pterm.Printfln("🤖 Adding registry '%s' to K2s cluster", registryName)

	psCmd, params, err := buildAddPsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image registry add")

	return nil
}

func buildAddPsCmd(registryName string, cmd *cobra.Command) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(c.SetupRootDir + "\\smallsetup\\helpers\\AddRegistry.ps1")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", p.OutputFlagName, err)
	}

	username, err := cmd.Flags().GetString(usernameFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", usernameFlag, err)
	}

	password, err := cmd.Flags().GetString(passwordFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", passwordFlag, err)
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	params = append(params,
		" -RegistryName "+utils.EscapeWithSingleQuotes(registryName),
		" -Username "+utils.EscapeWithSingleQuotes(username),
		" -Password "+utils.EscapeWithSingleQuotes(password))

	return
}
