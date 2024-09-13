// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/host"
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

// TODO: refactor
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

	// TODO: code clone!
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	cfg := context.Config()
	// TODO: code clone!
	setupConfig, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		// TODO: code clone!
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		// TODO: code clone!
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		return fmt.Errorf("could not load setup info to add the Windows user: %w", err)
	}

	psVersion := common.DeterminePsVersion(setupConfig)
	systemStatus, err := status.LoadStatus(psVersion)
	if err != nil {
		return fmt.Errorf("could not determine system status: %w", err)
	}

	if !systemStatus.RunningState.IsRunning {
		return common.CreateSystemNotRunningCmdFailure()
	}

	cmdExecutor := host.NewCmdExecutor(common.NewSlogWriter())
	userProvider := users.DefaultUserProvider()
	usersManagement, err := users.NewUsersManagement(setupConfig.ControlPlaneNodeHostname, cfg, cmdExecutor, userProvider)
	if err != nil {
		return err
	}

	if userName != "" {
		err = usersManagement.AddUserByName(userName)

	} else {
		err = usersManagement.AddUserById(userId)
	}

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

func newUserNotFoundFailure(err error) *common.CmdFailure {
	return &common.CmdFailure{
		Severity: common.SeverityWarning,
		Code:     "user-not-found",
		Message:  err.Error(),
	}
}
