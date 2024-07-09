// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/user"
	"path/filepath"
	"strings"

	"github.com/pterm/pterm"
	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/spf13/cobra"
)

const (
	userNameFlag = "username"
	userIdFlag   = "id"
	forceFlag    = "force"

	sshKeyName                     = "id_rsa"
	sshPubKeyName                  = sshKeyName + ".pub"
	commentPrefix                  = "k2s-"
	controlPlaneUserName           = "remote"
	controlPlaneAuthorizedKeysPath = "~/.ssh/authorized_keys"
)

func newAddCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add",
		Short: "EXPERIMENTAL - Grants a Windows user access to K2s",
		RunE:  run,
	}

	cmd.Flags().StringP(userNameFlag, "u", "", "Windows user name, e.g. 'johndoe' or 'johnsdomain\\johndoe'")
	cmd.Flags().StringP(userIdFlag, "i", "", "Windows user id, e.g. 'S-1-2-34-567898765-4321234567-8987654321-234567'")
	cmd.Flags().BoolP(forceFlag, "f", false, "Overwrite existing SSH key, K2s kubeconfig and Kubernetes certificates for the given user if existing without confirmation")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func run(cmd *cobra.Command, args []string) error {
	proceed, err := pterm.DefaultInteractiveConfirm.Show("This feature is experimental and incomplete and may lead to unexpected results, proceed anyways?")
	if err != nil {
		return err
	}
	if !proceed {
		return nil
	}

	slog.Info("Granting Windows user access to K2s..")

	userName, err := cmd.Flags().GetString(userNameFlag)
	if err != nil {
		return err
	}

	userId, err := cmd.Flags().GetString(userIdFlag)
	if err != nil {
		return err
	}

	force, err := cmd.Flags().GetBool(forceFlag)
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
	var foundUser *user.User

	if userName != "" {
		foundUser, err = user.Lookup(userName)
		if err != nil {
			return &common.CmdFailure{
				Severity: common.SeverityWarning,
				Code:     err.Error(),
				Message:  fmt.Sprintf("could not find Windows user by name '%s'", userName),
			}
		}
	} else {
		foundUser, err = user.LookupId(userId)
		if err != nil {
			return &common.CmdFailure{
				Severity: common.SeverityWarning,
				Code:     err.Error(),
				Message:  fmt.Sprintf("could not find Windows user by id '%s'", userId),
			}
		}
	}

	// TODO: more specific error messages

	slog.Debug("Win user found", "username", foundUser.Username, "id", foundUser.Uid, "homedir", foundUser.HomeDir, "group-id", foundUser.Gid) // omit user's display name for privacy reasons

	currentUser, err := user.Current()
	if err != nil {
		return err
	}

	slog.Info("current user", "username", currentUser.Username, "id", currentUser.Uid) // omit user's display name for privacy reasons

	// TODO: code clone!
	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
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

	sshDirName := filepath.Base(cfg.Host.SshDir)
	newUserSshControlPlaneDir := filepath.Join(foundUser.HomeDir, sshDirName, setupConfig.ControlPlaneNodeHostname)
	newUserSshKeyPath := filepath.Join(newUserSshControlPlaneDir, sshKeyName)
	newUserSshPubKeyPath := filepath.Join(newUserSshControlPlaneDir, sshPubKeyName)
	adminSshKeyPath := filepath.Join(cfg.Host.SshDir, setupConfig.ControlPlaneNodeHostname, sshKeyName)

	slog.Debug("Checking if SSH key is already existing", "path", newUserSshKeyPath)

	if host.PathExists(newUserSshKeyPath) {
		slog.Info("SSH key already existing", "path", newUserSshKeyPath)

		if force {
			slog.Info("Overwriting SSH key is enforced")
		} else {
			delete, err := pterm.DefaultInteractiveConfirm.Show("SSH key already existing for control-plane access, overwrite it anyways?")
			if err != nil {
				return err
			}
			if !delete {
				slog.Info("Granting user access aborted by user")
				return nil
			}

			slog.Info("Overwriting SSH key confirmed by user")
		}

		keyFiles, err := filepath.Glob(newUserSshKeyPath + "*")
		if err != nil {
			return err
		}

		slog.Debug("files to delete", "paths", keyFiles)

		for _, file := range keyFiles {
			if err := os.Remove(file); err != nil {
				return err
			}
			slog.Debug("file deleted", "path", file)
		}
	} else {
		slog.Debug("SSH key not existing", "path", newUserSshKeyPath)
	}

	host.CreateDirIfNotExisting(newUserSshControlPlaneDir)
	userComment := commentPrefix + strings.ReplaceAll(foundUser.Username, "\\", "-")

	exe := host.NewCmdExecutor(common.NewOutputWriter())

	if err := exe.ExecuteCmd("ssh-keygen.exe", "-f", newUserSshKeyPath, "-t", "rsa", "-b", "2048", "-C", userComment, "-N", ""); err != nil {
		return fmt.Errorf("SSH key generation failed: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/setowner", "Administrators"); err != nil {
		return fmt.Errorf("could not transfer ownership of SSH key to Administrators group: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/inheritance:d"); err != nil {
		return fmt.Errorf("could not remove security inheritance from SSH key: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/grant", fmt.Sprintf("%s:(F)", foundUser.Username)); err != nil {
		return fmt.Errorf("could not grant new user access to SSH key: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/remove:g", currentUser.Username); err != nil {
		return fmt.Errorf("could not revoke access to SSH key for admin user: %w", err)
	}

	controlePlaneCfg, found := lo.Find(cfg.Nodes, func(node config.NodeConfig) bool {
		return node.IsControlPlane
	})
	if !found {
		return errors.New("could not find control-plane node config")
	}

	controlPlaneAccess := fmt.Sprintf("%s@%s", controlPlaneUserName, controlePlaneCfg.IpAddress)
	pubKeyPathOnControlPlane := fmt.Sprintf("/tmp/%s", sshPubKeyName)
	controlPlaneRemovePubKeyCmd := fmt.Sprintf("rm -f %s", pubKeyPathOnControlPlane)

	slog.Debug("Removing existing pub SSH key from control-plane temp dir", "cmd", controlPlaneRemovePubKeyCmd)
	if err := exe.ExecuteCmd("ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", adminSshKeyPath, controlPlaneAccess, controlPlaneRemovePubKeyCmd); err != nil {
		return fmt.Errorf("could not remove existing SSH public key from control-plane temp dir: %w", err)
	}

	slog.Debug("Copying pub SSH key to control-plane temp dir", "source", newUserSshPubKeyPath, "target", pubKeyPathOnControlPlane)
	if err := exe.ExecuteCmd("scp.exe", "-o", "StrictHostKeyChecking=no", "-i", adminSshKeyPath, newUserSshPubKeyPath, fmt.Sprintf("%s:%s", controlPlaneAccess, pubKeyPathOnControlPlane)); err != nil {
		return fmt.Errorf("could not copy SSH public key to control-plane temp dir: %w", err)
	}

	controlPlaneAddPubKeyCmd := fmt.Sprintf("sudo sed -i '/.*%s.*/d' %s && sudo cat %s >> %s && rm -f %s", userComment, controlPlaneAuthorizedKeysPath, pubKeyPathOnControlPlane, controlPlaneAuthorizedKeysPath, pubKeyPathOnControlPlane)

	slog.Debug("Adding SSH public key to authorized keys file", "cmd", controlPlaneAddPubKeyCmd)
	if err := exe.ExecuteCmd("ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", adminSshKeyPath, controlPlaneAccess, controlPlaneAddPubKeyCmd); err != nil {
		return fmt.Errorf("could not add SSH public key to authorized keys file: %w", err)
	}

	pterm.Success.Println("DONE")

	return nil
}
