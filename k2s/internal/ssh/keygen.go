// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"log/slog"
)

type sshKeyGen struct {
	exec cmdExecutor
}

const (
	keyType       = "rsa"
	keyBits       = "2048"
	keyPassphrase = ""
)

func NewSshKeyGen(cmdExecutor cmdExecutor) *sshKeyGen {
	return &sshKeyGen{
		exec: cmdExecutor,
	}
}

func (gen *sshKeyGen) CreateKey(outKeyFile string, comment string) error {
	slog.Debug("Creating SSH key", "out-file", outKeyFile, "comment", comment)

	if err := gen.exec.ExecuteCmd("ssh-keygen.exe", "-f", outKeyFile, "-t", keyType, "-b", keyBits, "-C", comment, "-N", keyPassphrase); err != nil {
		return fmt.Errorf("could not generate SSH key '%s': %w", outKeyFile, err)
	}
	return nil
}
