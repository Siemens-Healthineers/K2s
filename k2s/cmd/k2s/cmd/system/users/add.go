// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/os"
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
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func run(cmd *cobra.Command, args []string) error {
	slog.Info("Granting Windows user access to K2s..")

	start := time.Now()

	userName, err := cmd.Flags().GetString(userNameFlag)
	if err != nil {
		return err
	}

	userId, err := cmd.Flags().GetString(userIdFlag)
	if err != nil {
		return err
	}

	if (userName == "" && userId == "") || (userName != "" && userId != "") {
		return &common.CmdFailure{
			Severity: common.SeverityWarning,
			Code:     "users-add-parameter-validation-failed",
			Message:  "either user name (-u) or user id (-i) must be specified",
		}
	}

	config := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext).Config()

	setupConfig, err := loadSetupConfig(config.Host.K2sConfigDir)
	if err != nil {
		return err
	}

	psVersion := common.DeterminePsVersion(setupConfig)
	systemStatus, err := status.LoadStatus(psVersion)
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	err = addUserFunc(userName, userId, config)()
	if err != nil {
		var userNotFoundErr users.UserNotFoundErr
		if errors.As(err, &userNotFoundErr) {
			return newUserNotFoundFailure(userNotFoundErr)
		}
		return err
	}

	common.PrintCompletedMessage(time.Since(start), cmd.CommandPath())
	return nil
}

func loadSetupConfig(configDir string) (*setupinfo.Config, error) {
	setupConfig, err := setupinfo.ReadConfig(configDir)
	if err == nil {
		return setupConfig, nil
	}

	if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
		return nil, common.CreateSystemNotInstalledCmdFailure()
	}
	if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
		return nil, common.CreateSystemInCorruptedStateCmdFailure()
	}
	return nil, fmt.Errorf("could not load setup info to add the Windows user: %w", err)
}

func addUserFunc(userName, userId string, cfg *config.Config) func() error {
	cmdExecutor := os.NewCmdExecutor(common.NewSlogWriter())
	userProvider := users.DefaultUserProvider()
	usersManagement, err := users.NewUsersManagement(cfg, cmdExecutor, userProvider)
	if err != nil {
		return func() error { return err }
	}

	if userName != "" {
		return func() error { return usersManagement.AddUserByName(userName) }

	}
	return func() error { return usersManagement.AddUserById(userId) }
}

func newUserNotFoundFailure(err error) *common.CmdFailure {
	return &common.CmdFailure{
		Severity: common.SeverityWarning,
		Code:     "user-not-found",
		Message:  err.Error(),
	}
}
