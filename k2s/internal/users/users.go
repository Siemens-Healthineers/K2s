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

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
)

type UserNotFoundErr string

type UsersManagement struct {
	controlPlaneName string
	cfg              *config.Config
	confirmOverwrite func() bool
	stdWriter        host.StdWriter
}

const (
	sshKeyName                     = "id_rsa"
	sshPubKeyName                  = sshKeyName + ".pub"
	commentPrefix                  = "k2s-"
	controlPlaneUserName           = "remote"
	controlPlaneAuthorizedKeysPath = "~/.ssh/authorized_keys"
)

func NewUsersManagement(controlPlaneName string, cfg *config.Config, confirmOverwrite func() bool, stdWriter host.StdWriter) *UsersManagement {
	return &UsersManagement{
		controlPlaneName: controlPlaneName,
		cfg:              cfg,
		confirmOverwrite: confirmOverwrite,
		stdWriter:        stdWriter,
	}
}

func (e UserNotFoundErr) Error() string {
	return string(e)
}

func (um *UsersManagement) AddUserByName(name string) error {
	winUser, err := user.Lookup(name)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by name '%s'", name))
	}

	return um.addUser(*winUser)
}

func (um *UsersManagement) AddUserById(id string) error {
	winUser, err := user.LookupId(id)
	if err != nil {
		return UserNotFoundErr(fmt.Sprintf("could not find Windows user by id '%s'", id))
	}

	return um.addUser(*winUser)
}

// TODO: more specific error messages
func (um *UsersManagement) addUser(winUser user.User) error {
	slog.Debug("Adding Windows user", "username", winUser.Username, "id", winUser.Uid, "homedir", winUser.HomeDir, "group-id", winUser.Gid) // omit user's display name for privacy reasons

	currentUser, err := user.Current()
	if err != nil {
		return err
	}

	slog.Debug("current user", "username", currentUser.Username, "id", currentUser.Uid) // omit user's display name for privacy reasons

	sshDirName := filepath.Base(um.cfg.Host.SshDir)
	newUserSshControlPlaneDir := filepath.Join(winUser.HomeDir, sshDirName, um.controlPlaneName)
	newUserSshKeyPath := filepath.Join(newUserSshControlPlaneDir, sshKeyName)
	newUserSshPubKeyPath := filepath.Join(newUserSshControlPlaneDir, sshPubKeyName)
	adminSshKeyPath := filepath.Join(um.cfg.Host.SshDir, um.controlPlaneName, sshKeyName)

	slog.Debug("Checking if SSH key is already existing", "path", newUserSshKeyPath)

	if host.PathExists(newUserSshKeyPath) {
		slog.Debug("SSH key already existing, requiring confirmation", "path", newUserSshKeyPath)

		if !um.confirmOverwrite() {
			slog.Debug("Overwriting SSH key aborted")
			return nil
		}

		slog.Debug("Overwriting SSH key confirmed")

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
	userComment := commentPrefix + strings.ReplaceAll(winUser.Username, "\\", "-")

	exe := host.NewCmdExecutor(um.stdWriter)

	if err := exe.ExecuteCmd("ssh-keygen.exe", "-f", newUserSshKeyPath, "-t", "rsa", "-b", "2048", "-C", userComment, "-N", ""); err != nil {
		return fmt.Errorf("SSH key generation failed: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/setowner", "Administrators"); err != nil {
		return fmt.Errorf("could not transfer ownership of SSH key to Administrators group: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/inheritance:d"); err != nil {
		return fmt.Errorf("could not remove security inheritance from SSH key: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/grant", fmt.Sprintf("%s:(F)", winUser.Username)); err != nil {
		return fmt.Errorf("could not grant new user access to SSH key: %w", err)
	}

	if err := exe.ExecuteCmd("icacls", newUserSshKeyPath, "/t", "/remove:g", currentUser.Username); err != nil {
		return fmt.Errorf("could not revoke access to SSH key for admin user: %w", err)
	}

	controlePlaneCfg, found := lo.Find(um.cfg.Nodes, func(node config.NodeConfig) bool {
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

	return nil
}
