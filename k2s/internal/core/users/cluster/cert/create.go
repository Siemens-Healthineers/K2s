// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cert

import (
	"crypto/rand"
	"fmt"
	"log/slog"
	"path"

	"github.com/siemens-healthineers/k2s/internal/definitions"
)

type remoteExecutor interface {
	Exec(command string) error
}

type RemoteCertCreator struct {
	remoteExecutor remoteExecutor
}

const (
	privateKeyBits = 4096
	certValidDays  = 365
	k8sCaCertPath  = "/etc/kubernetes/pki/ca.crt"
	k8sCaKeyPath   = "/etc/kubernetes/pki/ca.key"
)

func NewRemoteCertCreator(remoteExecutor remoteExecutor) *RemoteCertCreator {
	return &RemoteCertCreator{
		remoteExecutor: remoteExecutor,
	}
}

func (c *RemoteCertCreator) Create(userName string) (tempRemoteDir, keyFileName, certFileName string, err error) {
	slog.Debug("Creating user cert signed by K8s CA", "user-name", userName)

	tempRemoteDir = path.Join("/tmp/", rand.Text())
	keyFileName = userName + ".key"
	certFileName = userName + ".crt"

	keyRemotePath := path.Join(tempRemoteDir, keyFileName)
	certRemotePath := path.Join(tempRemoteDir, certFileName)
	signRequestPath := path.Join(tempRemoteDir, userName+".csr")

	createDirCmd := "mkdir " + tempRemoteDir
	generateKeyCmd := fmt.Sprintf("openssl genrsa -out %s %d 2>&1", keyRemotePath, privateKeyBits)
	createSignRequestCmd := fmt.Sprintf("openssl req -new -key %s -out %s -subj \"\"/CN=%s/O=%s\"\" 2>&1", keyRemotePath, signRequestPath, userName, definitions.K2sUserGroup)
	signCertCmd := fmt.Sprintf("sudo openssl x509 -req -in %s -CA %s -CAkey %s -CAcreateserial -out %s -days %d 2>&1", signRequestPath, k8sCaCertPath, k8sCaKeyPath, certRemotePath, certValidDays)
	removeSignRequestCmd := "rm -f " + signRequestPath

	createUserCertCmd := createDirCmd + " && " +
		generateKeyCmd + " && " +
		createSignRequestCmd + " && " +
		signCertCmd + " && " +
		removeSignRequestCmd

	if err := c.remoteExecutor.Exec(createUserCertCmd); err != nil {
		return "", "", "", fmt.Errorf("failed to create user cert signed by K8s CA: %w", err)
	}

	slog.Debug("User cert signed by K8s CA created", "user-name", userName, "cert-path", certRemotePath, "key-path", keyRemotePath)
	return
}
