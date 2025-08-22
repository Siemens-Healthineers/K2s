// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package keyauth

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/ssh"
)

type remoteAccessProvider interface {
	Exec(command string) error
	Copy(copyOptions ssh.CopyOptions) error
}

type KeyAuthorizer struct {
	remoteAccessProvider remoteAccessProvider
}

const authorizedKeysPath = "~/.ssh/authorized_keys"

func NewKeyAuthorizer(remoteAccessProvider remoteAccessProvider) *KeyAuthorizer {
	return &KeyAuthorizer{remoteAccessProvider: remoteAccessProvider}
}

func (k *KeyAuthorizer) AuthorizePubKeyOnRemote(publicKeyPath, publicKeyComment string) error {
	slog.Debug("Authorizing public SSH key on remote machine", "path", publicKeyPath, "comment", publicKeyComment)

	pubKeyName := filepath.Base(publicKeyPath)
	remotePubKeyPath := "/tmp/" + pubKeyName
	removeRemotePubKeyCmd := "rm -f " + remotePubKeyPath

	slog.Debug("Removing existing public SSH key from remote machine", "path", remotePubKeyPath)
	if err := k.remoteAccessProvider.Exec(removeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("failed to remove existing SSH public key '%s' from remote machine: %w", remotePubKeyPath, err)
	}

	slog.Debug("Copying public SSH key to remote machine", "path", remotePubKeyPath)
	copyOptions := ssh.CopyOptions{
		Source:    publicKeyPath,
		Target:    remotePubKeyPath,
		Direction: ssh.CopyToNode,
	}

	if err := k.remoteAccessProvider.Copy(copyOptions); err != nil {
		return fmt.Errorf("failed to copy public SSH key to remote machine: %w", err)
	}

	deleteObsoletePubKeyFromAuthKeys := fmt.Sprintf("sudo sed -i '/.*%s.*/d' %s", publicKeyComment, authorizedKeysPath)
	addNewPubKeyToAuthKeys := fmt.Sprintf("sudo cat %s >> %s", remotePubKeyPath, authorizedKeysPath)
	removePubKeyFile := "rm -f " + remotePubKeyPath

	authorizeRemotePubKeyCmd := deleteObsoletePubKeyFromAuthKeys + " && " +
		addNewPubKeyToAuthKeys + " && " +
		removePubKeyFile

	slog.Debug("Adding public SSH key to authorized keys file on remote machine")
	if err := k.remoteAccessProvider.Exec(authorizeRemotePubKeyCmd); err != nil {
		return fmt.Errorf("failed to add public SSH key to authorized keys file: %w", err)
	}

	slog.Debug("Public SSH key authorized on remote machine", "path", publicKeyPath, "comment", publicKeyComment)
	return nil
}
