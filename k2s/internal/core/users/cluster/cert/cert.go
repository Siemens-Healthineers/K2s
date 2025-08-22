// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cert

import (
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/contracts/ssh"
)

type remoteCertCreator interface {
	Create(userName string) (tempRemoteDir, keyFileName, certFileName string, err error)
}

type remoteMover interface {
	Move(copyOptions ssh.CopyOptions) error
}

type CertGenerator struct {
	remoteCertCreator remoteCertCreator
	remoteMover       remoteMover
}

func NewCertGenerator(remoteCertCreator remoteCertCreator, remoteCertMover remoteMover) *CertGenerator {
	return &CertGenerator{
		remoteCertCreator: remoteCertCreator,
		remoteMover:       remoteCertMover,
	}
}

func (c *CertGenerator) GenerateUserCert(userName string, targetDir string) (certPath, keyPath string, err error) {
	slog.Debug("Generating user cert", "user-name", userName, "target-dir", targetDir)

	tempRemoteDir, keyFileName, certFileName, err := c.remoteCertCreator.Create(userName)
	if err != nil {
		return "", "", fmt.Errorf("failed to create user certificate on remote machine for user '%s': %w", userName, err)
	}

	options := ssh.CopyOptions{
		Source:    tempRemoteDir,
		Target:    targetDir,
		Direction: ssh.CopyFromNode,
	}

	err = c.remoteMover.Move(options)
	if err != nil {
		return "", "", fmt.Errorf("failed to move user certificate files from remote machine for user '%s': %w", userName, err)
	}

	tempDirName := filepath.Base(tempRemoteDir)
	certPath = filepath.Join(targetDir, tempDirName, certFileName)
	keyPath = filepath.Join(targetDir, tempDirName, keyFileName)

	slog.Debug("User cert generated", "user-name", userName, "target-dir", targetDir, "cert-path", certPath, "key-path", keyPath)
	return
}
