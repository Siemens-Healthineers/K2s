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

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

var (
	updateExample = `
	# Update registry in K2s (enter credentials afterwards)
	k2s image registry update myregistry

	# Update registry in K2s (enter credentials afterwards) and configure as insecure registry (skips verifying HTTPS certs, and allows falling back to plain HTTP)
	k2s image registry update myregistry --skip-verify --plain-http

	# Update registry with username and password in K2s 
	k2s image registry update myregistry -u testuser -p testpassword
`

	updateCmd = &cobra.Command{
		Use:     "update",
		Short:   "Update container registry",
		RunE:    updateRegistry,
		Example: updateExample,
	}
)

func init() {
	updateCmd.Flags().StringP(passwordFlag, "p", "", passwordFlag)
	updateCmd.Flags().StringP(usernameFlag, "u", "", usernameFlag)
	updateCmd.Flags().Bool(skipVerifyFlag, false, "Skips verifying HTTPS certs")
	updateCmd.Flags().Bool(plainHttpFlag, false, "Allows falling back to plain HTTP")
	updateCmd.Flags().SortFlags = false
	updateCmd.Flags().PrintDefaults()
}

func updateRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry update <registry-name>'")
	}

	registryName := args[0]

	slog.Info("Updating registry", "registry", registryName)

	pterm.Printfln("🤖 Updating registry '%s' to K2s cluster", registryName)

	psCmd, params, err := buildUpdatePsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
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

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image registry update")

	return nil
}

func buildUpdatePsCmd(registryName string, cmd *cobra.Command) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "registry", "Update-Registry.ps1"))

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

	skipVerify, err := strconv.ParseBool(cmd.Flags().Lookup(skipVerifyFlag).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", skipVerifyFlag, err)
	}

	plainHttp, err := strconv.ParseBool(cmd.Flags().Lookup(plainHttpFlag).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", plainHttpFlag, err)
	}

	if plainHttp {
		params = append(params, " -PlainHttp")
	}

	if skipVerify {
		params = append(params, " -SkipVerify")
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
