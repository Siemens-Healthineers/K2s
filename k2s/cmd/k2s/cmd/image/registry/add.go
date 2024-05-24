// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
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

	slog.Info("Adding registry", "registry", registryName)

	pterm.Printfln("🤖 Adding registry '%s' to K2s cluster", registryName)

	psCmd, params, err := buildAddPsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
	}

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), outputWriter, params...)
	if err != nil {
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
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "registry", "Add-Registry.ps1"))

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
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
