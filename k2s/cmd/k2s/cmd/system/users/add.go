// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"

	"github.com/pterm/pterm"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/spf13/cobra"
)

const (
	userNameFlag = "username"
	userIdFlag   = "id"
	forceFlag    = "force"
)

func newAddCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "Grants a Windows user access to K2s",
		RunE:  run,
	}

	cmd.Flags().StringP(userNameFlag, "u", "", "Windows user name, e.g. 'johndoe' or 'johnsdomain\\johndoe'")
	cmd.Flags().StringP(userIdFlag, "i", "", "Windows user id, e.g. 'S-1-2-34-567898765-4321234567-8987654321-234567'")
	cmd.Flags().BoolP(forceFlag, "f", false, "Overwrite existing SSH key, K2s kubeconfig and Kubernetes certificates for the given user if existing without confirmation")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

// TODO: refactor
func run(cmd *cobra.Command, args []string) error {
	slog.Info("Granting Windows user access to K2s..")

	userName, err := cmd.Flags().GetString(userNameFlag)
	if err != nil {
		return err
	}

	userId, err := cmd.Flags().GetString(userIdFlag)
	if err != nil {
		return err
	}

	forceOverwrite, err := cmd.Flags().GetBool(forceFlag)
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
	// TODO: code clone!
	setupConfig, err := setupinfo.ReadConfig(context.Config().Host.K2sConfigDir)
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

	usersManagement, err := newUsersManagement(setupConfig.ControlPlaneNodeHostname, context.Config(), forceOverwrite)
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

		var overwriteAbortedErr users.OverwriteAbortedErr
		if errors.As(err, &overwriteAbortedErr) {
			pterm.Info.Println("Aborted by user")
			return nil
		}
		return err
	}

	pterm.Success.Println("Granted Windows user access to K2s")
	return nil
}

func newUsersManagement(controlPlaneName string, cfg *config.Config, forceOverwrite bool) (*users.UsersManagement, error) {
	umConfig := &users.UsersManagementConfig{
		ControlPlaneName:     controlPlaneName,
		Config:               cfg,
		ConfirmOverwriteFunc: func() bool { return confirmOverwrite(forceOverwrite, pterm.DefaultInteractiveConfirm.Show) },
		StdWriter:            common.NewSlogWriter(),
	}

	return users.NewUsersManagement(umConfig)
}

func newUserNotFoundFailure(err error) *common.CmdFailure {
	return &common.CmdFailure{
		Severity: common.SeverityWarning,
		Code:     "user-not-found",
		Message:  err.Error(),
	}
}

func confirmOverwrite(force bool, showConfirmation func(...string) (bool, error)) bool {
	if force {
		slog.Info("Overwriting existing access is enforced")
		return true
	}

	confirmed, err := showConfirmation("Windows user already granted access to K2s, overwrite existing access anyway?")
	if err != nil {
		slog.Error("cannot show confirmation", "error", err)
		return false
	}

	if !confirmed {
		slog.Info("Overwriting existing access aborted by user")
		return false
	}

	slog.Info("Overwriting existing access confirmed by user")
	return true
}
