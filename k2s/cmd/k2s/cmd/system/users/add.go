// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	config_contract "github.com/siemens-healthineers/k2s/internal/contracts/config"
	users_contract "github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/users"
	"github.com/spf13/cobra"
)

type UsersManagement interface {
	AddUserByName(name string) error
	AddUserById(id string) error
}

const (
	userNameFlag = "username"
	userIdFlag   = "id"
)

func newAddCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Grants a Windows user access to K2s",
		RunE:  run,
	}

	cmd.Flags().StringP(userNameFlag, "u", "", "Windows user name, e.g. 'johndoe' or 'johnsdomain\\johndoe'")
	cmd.Flags().StringP(userIdFlag, "i", "", "Windows user id, e.g. 'S-1-2-34-567898765-4321234567-8987654321-234567'")

	cmd.MarkFlagsMutuallyExclusive(userNameFlag, userIdFlag)
	cmd.MarkFlagsOneRequired(userNameFlag, userIdFlag)

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func run(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	userName, err := cmd.Flags().GetString(userNameFlag)
	if err != nil {
		return err
	}

	userId, err := cmd.Flags().GetString(userIdFlag)
	if err != nil {
		return err
	}

	k2sConfig := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()

	runtimeConfig, err := loadSetupConfig(k2sConfig.Host().K2sSetupConfigDir())
	if err != nil {
		return err
	}

	systemStatus, err := status.LoadStatus()
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	addUserIntegration := users.NewAddUserIntegration(k2sConfig, runtimeConfig, users.WinUsersProvider())

	if userName != "" {
		err = addUserIntegration.AddByName(userName)
	} else {
		err = addUserIntegration.AddById(userId)
	}
	if err != nil {
		var userNotFoundErr users_contract.ErrUserNotFound
		if errors.As(err, &userNotFoundErr) {
			return newUserNotFoundFailure(userNotFoundErr)
		}
		return fmt.Errorf("failed to add user: %w", err)
	}

	cmdSession.Finish()

	return nil
}

func loadSetupConfig(configDir string) (*config_contract.K2sRuntimeConfig, error) {
	setupConfig, err := config.ReadRuntimeConfig(configDir)
	if err == nil {
		return setupConfig, nil
	}

	if errors.Is(err, config_contract.ErrSystemNotInstalled) {
		return nil, common.CreateSystemNotInstalledCmdFailure()
	}
	if errors.Is(err, config_contract.ErrSystemInCorruptedState) {
		return nil, common.CreateSystemInCorruptedStateCmdFailure()
	}
	return nil, fmt.Errorf("could not load setup info to add the Windows user: %w", err)
}

func newUserNotFoundFailure(err error) *common.CmdFailure {
	return &common.CmdFailure{
		Severity: common.SeverityWarning,
		Code:     "user-not-found",
		Message:  err.Error(),
	}
}
