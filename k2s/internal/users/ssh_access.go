// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"
	"os/user"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/ssh"
	"github.com/siemens-healthineers/k2s/internal/windows/acl"
)

type sshKeyGen interface {
	CreateKey(keyPath string, comment string) error
}

type OverwriteAbortedErr string

type accessControl interface {
	SetOwner(path string, owner string) error
	RemoveInheritance(path string) error
	GrantFullAccess(path string, username string) error
	RevokeAccess(path string, username string) error
}

type sshAccessGranter struct {
	*commonAccessGranter
	confirmOverwrite func() bool
	sshKeyGen        sshKeyGen
	accessControl    accessControl
	sshDirName       string
}

const (
	sshKeyName         = "id_rsa"
	sshPubKeyName      = sshKeyName + ".pub"
	authorizedKeysPath = "~/.ssh/authorized_keys"
)

func newSshAccessGranter(accessGranter *commonAccessGranter, confirmOverwrite func() bool, sshDirName string) accessGranter {
	return &sshAccessGranter{
		commonAccessGranter: accessGranter,
		confirmOverwrite:    confirmOverwrite,
		sshKeyGen:           ssh.NewSshKeyGen(accessGranter.cmdExecutor),
		accessControl:       acl.NewAcl(accessGranter.cmdExecutor),
		sshDirName:          sshDirName,
	}
}

func (e OverwriteAbortedErr) Error() string {
	return string(e)
}

func (g *sshAccessGranter) GrantAccess(winUser user.User, k2sUserName string) error {
	newUserSshControlPlaneDir := filepath.Join(winUser.HomeDir, g.sshDirName, g.controlPlane.Name())
	newUserSshKeyPath := filepath.Join(newUserSshControlPlaneDir, sshKeyName)

	if err := g.createSshKey(newUserSshKeyPath, k2sUserName); err != nil {
		return fmt.Errorf("could not create SSH key '%s' for user '%s': %w", newUserSshKeyPath, k2sUserName, err)
	}

	if err := g.transferKeyOwnership(newUserSshKeyPath, winUser.Username); err != nil {
		return fmt.Errorf("could not transfer ownership of key file '%s' to '%s': %w", newUserSshKeyPath, winUser.Username, err)
	}

	if err := g.authorizePubKeyOnControlPlane(newUserSshControlPlaneDir, k2sUserName); err != nil {
		return fmt.Errorf("could not authorize public key on control-plane: %w", err)
	}
	return nil
}

func (g *sshAccessGranter) createSshKey(keyPath string, keyComment string) error {
	slog.Debug("Checking if SSH key is already existing", "path", keyPath)

	if host.PathExists(keyPath) {
		slog.Debug("SSH key already existing, requiring confirmation", "path", keyPath)

		if !g.confirmOverwrite() {
			return OverwriteAbortedErr("Overwriting SSH key aborted")
		}

		slog.Debug("Overwriting SSH key confirmed")

		keyFiles, err := filepath.Glob(keyPath + "*")
		if err != nil {
			return fmt.Errorf("could not determine SSH key files: %w", err)
		}

		if err := host.RemoveFiles(keyFiles...); err != nil {
			return fmt.Errorf("could not delete existing SSH key files: %w", err)
		}
	} else {
		slog.Debug("SSH key not existing", "path", keyPath)
	}

	host.CreateDirIfNotExisting(filepath.Dir(keyPath))

	slog.Debug("Generating SSH key for new user", "key-path", keyPath)

	if err := g.sshKeyGen.CreateKey(keyPath, keyComment); err != nil {
		return fmt.Errorf("could not generate SSH key '%s' for new user: %w", keyPath, err)
	}
	return nil
}

func (g *sshAccessGranter) transferKeyOwnership(keyPath string, newOwner string) error {
	if err := g.accessControl.SetOwner(keyPath, "Administrators"); err != nil {
		return fmt.Errorf("could not set owner of SSH key to Administrators group: %w", err)
	}

	if err := g.accessControl.RemoveInheritance(keyPath); err != nil {
		return fmt.Errorf("could not remove security inheritance from SSH key: %w", err)
	}

	if err := g.accessControl.GrantFullAccess(keyPath, newOwner); err != nil {
		return fmt.Errorf("could not grant new user full access to SSH key: %w", err)
	}

	admin, err := user.Current()
	if err != nil {
		return fmt.Errorf("could not determine current Windows user: %w", err)
	}

	slog.Debug("Admin determined", "username", admin.Username, "id", admin.Uid) // omit user's display name for privacy reasons

	if err := g.accessControl.RevokeAccess(keyPath, admin.Username); err != nil {
		return fmt.Errorf("could not revoke access to SSH key for admin user: %w", err)
	}
	return nil
}

func (g *sshAccessGranter) authorizePubKeyOnControlPlane(keyDir string, k2sUserName string) error {
	localPubKeyPath := filepath.Join(keyDir, sshPubKeyName)
	remotePubKeyPath := fmt.Sprintf("/tmp/%s", sshPubKeyName)
	removeRemotePubKeyCmd := fmt.Sprintf("rm -f %s", remotePubKeyPath)

	slog.Debug("Removing existing pub SSH key from control-plane temp dir")
	if err := g.controlPlane.Exec(removeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("could not remove existing SSH public key from control-plane temp dir: %w", err)
	}

	slog.Debug("Copying pub SSH key to control-plane temp dir")
	if err := g.controlPlane.CopyTo(localPubKeyPath, remotePubKeyPath); err != nil {
		return fmt.Errorf("could not copy SSH public key to control-plane temp dir: %w", err)
	}

	deleteObsoletePubKeyFromAuthKeys := fmt.Sprintf("sudo sed -i '/.*%s.*/d' %s", k2sUserName, authorizedKeysPath)
	addNewPubKeyToAuthKeys := fmt.Sprintf("sudo cat %s >> %s", remotePubKeyPath, authorizedKeysPath)
	removePubKeyFile := "rm -f " + remotePubKeyPath

	authorizeRemotePubKeyCmd := deleteObsoletePubKeyFromAuthKeys + " && " +
		addNewPubKeyToAuthKeys + " && " +
		removePubKeyFile

	slog.Debug("Adding SSH public key to authorized keys file")
	if err := g.controlPlane.Exec(authorizeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("could not add SSH public key to authorized keys file: %w", err)
	}
	return nil
}
