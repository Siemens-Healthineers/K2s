// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
)

const (
	usernameFlag   = "username"
	passwordFlag   = "password"
	skipVerifyFlag = "skip-verify"
	plainHttpFlag  = "plain-http"
)

var (
	addExample = `
	# Add registry in K2s (enter credentials afterwards)
	k2s image registry add ghcr.io

	# Add registry in K2s (enter credentials afterwards) and configure as insecure registry (skips verifying HTTPS certs, and allows falling back to plain HTTP)
	k2s image registry add ghcr.io --skip-verify --plain-http

	# Add registry with username and password in K2s 
	k2s image registry add ghcr.io -u testuser -p testpassword
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
	addCmd.Flags().Bool(skipVerifyFlag, false, "Skips verifying HTTPS certs")
	addCmd.Flags().Bool(plainHttpFlag, false, "Allows falling back to plain HTTP")
	addCmd.Flags().SortFlags = false
	addCmd.Flags().PrintDefaults()
}

func addRegistry(cmd *cobra.Command, args []string) error {
	if len(args) == 0 || args[0] == "" {
		return errors.New("no registry passed in CLI, use e.g. 'k2s image registry add <registry-name>'")
	}

	cmdSession := common.StartCmdSession(cmd.CommandPath())
	registryName := args[0]

	slog.Info("Adding registry", "registry", registryName)

	pterm.Printfln("🤖 Adding registry '%s' to K2s cluster", registryName)

	psCmd, params, err := buildAddPsCmd(registryName, cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
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
