// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"

	"path/filepath"
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

type currentUserFinder interface {
	Current() (WinUser, error)
}

type sshAccessGranter struct {
	*commonAccessGranter
	userFinder    currentUserFinder
	sshKeyGen     sshKeyGen
	accessControl accessControl
	adminSshDir   string
}

const (
	sshKeyName         = "id_rsa"
	sshPubKeyName      = sshKeyName + ".pub"
	authorizedKeysPath = "~/.ssh/authorized_keys"
)

func (g *sshAccessGranter) GrantAccess(winUser WinUser, k2sUserName string) (err error) {
	sshDirName := filepath.Base(g.adminSshDir)
	newUserSshDir := filepath.Join(winUser.HomeDir(), sshDirName)
	newUserSshControlPlaneDir := filepath.Join(newUserSshDir, g.controlPlane.Name())
	newUserSshKeyPath := filepath.Join(newUserSshControlPlaneDir, sshKeyName)

	if err = g.createSshKey(newUserSshKeyPath, k2sUserName); err != nil {
		return fmt.Errorf("could not create SSH key '%s' for user '%s': %w", newUserSshKeyPath, k2sUserName, err)
	}

	if err = g.transferKeyOwnership(newUserSshKeyPath, winUser.Username()); err != nil {
		return fmt.Errorf("could not transfer ownership of key file '%s' to '%s': %w", newUserSshKeyPath, winUser.Username(), err)
	}

	tasks := sync.WaitGroup{}
	tasks.Add(2)

	go func() {
		defer tasks.Done()
		if innerErr := g.authorizePubKeyOnControlPlane(newUserSshControlPlaneDir, k2sUserName); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("could not authorize public key on control-plane: %w", innerErr))
		}
	}()

	go func() {
		defer tasks.Done()
		if innerErr := g.addControlPlaneToKnownHosts(newUserSshDir); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("could not add control-plane fingerprint to known_hosts: %w", innerErr))
		}
	}()

	tasks.Wait()

	return err
}

func (g *sshAccessGranter) createSshKey(keyPath string, keyComment string) error {
	slog.Debug("Checking if SSH key is already existing", "path", keyPath)

	if g.fs.PathExists(keyPath) {
		slog.Debug("SSH key already existing, overwriting it", "path", keyPath)

		if err := g.removeSShKey(keyPath); err != nil {
			return err
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

func (g *sshAccessGranter) removeSShKey(keyPath string) error {
	keyFiles, err := filepath.Glob(keyPath + "*")
	if err != nil {
		return fmt.Errorf("could not determine SSH key files: %w", err)
	}

	if err := g.fs.RemovePaths(keyFiles...); err != nil {
		return fmt.Errorf("could not delete existing SSH key files: %w", err)
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

	admin, err := g.userFinder.Current()
	if err != nil {
		return fmt.Errorf("could not determine current Windows user: %w", err)
	}

	slog.Debug("Admin determined", "username", admin.Username, "id", admin.UserId)

	if err := g.accessControl.RevokeAccess(keyPath, admin.Username()); err != nil {
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
