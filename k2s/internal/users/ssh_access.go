// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"fmt"
	"log/slog"
	"os/user"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/ssh"
	"github.com/siemens-healthineers/k2s/internal/windows/acl"
)

type sshKeyGen interface {
	CreateKey(keyPath string, comment string) error
	FindHostInKnownHosts(host string, sshDir string) (hostEntry string, found bool)
	SetHostInKnownHosts(hostEntry string, sshDir string) error
}

type accessControl interface {
	SetOwner(path string, owner string) error
	RemoveInheritance(path string) error
	GrantFullAccess(path string, username string) error
	RevokeAccess(path string, username string) error
}

type OverwriteAbortedErr string

type sshAccessGranter struct {
	*commonAccessGranter
	confirmOverwrite func() bool
	currentUser      func() (*user.User, error)
	sshKeyGen        sshKeyGen
	accessControl    accessControl
	adminSshDir      string
}

const (
	sshKeyName         = "id_rsa"
	sshPubKeyName      = sshKeyName + ".pub"
	authorizedKeysPath = "~/.ssh/authorized_keys"
)

func newSshAccessGranter(accessGranter *commonAccessGranter, confirmOverwrite func() bool, sshDir string, currentUser func() (*user.User, error)) accessGranter {
	return &sshAccessGranter{
		commonAccessGranter: accessGranter,
		confirmOverwrite:    confirmOverwrite,
		sshKeyGen:           ssh.NewSshKeyGen(accessGranter.exec, accessGranter.fs),
		accessControl:       acl.NewAcl(accessGranter.exec),
		adminSshDir:         sshDir,
		currentUser:         currentUser,
	}
}

func (e OverwriteAbortedErr) Error() string {
	return string(e)
}

func (g *sshAccessGranter) GrantAccess(winUser user.User, k2sUserName string) error {
	sshDirName := filepath.Base(g.adminSshDir)
	newUserSshDir := filepath.Join(winUser.HomeDir, sshDirName)
	newUserSshControlPlaneDir := filepath.Join(newUserSshDir, g.controlPlane.Name())
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

	if err := g.addControlPlaneToKnownHosts(newUserSshDir); err != nil {
		return fmt.Errorf("could not add control-plane fingerprint to known_hosts: %w", err)
	}
	return nil
}

func (g *sshAccessGranter) createSshKey(keyPath string, keyComment string) error {
	slog.Debug("Checking if SSH key is already existing", "path", keyPath)

	if g.fs.PathExists(keyPath) {
		slog.Debug("SSH key already existing, requiring confirmation", "path", keyPath)

		if !g.confirmOverwrite() {
			return OverwriteAbortedErr("Overwriting SSH key aborted")
		}

		slog.Debug("Overwriting SSH key confirmed")

		keyFiles, err := filepath.Glob(keyPath + "*")
		if err != nil {
			return fmt.Errorf("could not determine SSH key files: %w", err)
		}

		if err := g.fs.RemovePaths(keyFiles...); err != nil {
			return fmt.Errorf("could not delete existing SSH key files: %w", err)
		}
	} else {
		slog.Debug("SSH key not existing", "path", keyPath)
	}

	g.fs.CreateDirIfNotExisting(filepath.Dir(keyPath))

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

	admin, err := g.currentUser()
	if err != nil {
		return fmt.Errorf("could not determine current Windows user: %w", err)
	}

	// omit user's display name for privacy reasons
	slog.Debug("Admin determined", "username", admin.Username, "id", admin.Uid)

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

func (g *sshAccessGranter) addControlPlaneToKnownHosts(newUserSshDir string) error {
	controlPlaneEntry, found := g.sshKeyGen.FindHostInKnownHosts(g.controlPlane.IpAddress(), g.adminSshDir)
	if !found {
		return fmt.Errorf("could not find any control-plane entry for host '%s' in '%s'", g.controlPlane.IpAddress(), g.adminSshDir)
	}

	if err := g.sshKeyGen.SetHostInKnownHosts(controlPlaneEntry, newUserSshDir); err != nil {
		return fmt.Errorf("could not add control-plane entry to new user's known_hosts: %w", err)
	}
	return nil
}
