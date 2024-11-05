// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"path/filepath"
)

const (
	SshPubKeyName = sshKeyName + ".pub"

	sshKeyName    = "id_rsa"
	sshSubDirName = "kubemaster" // TODO: this will change to a more generic sub dir name in the near future
)

func SshKeyPath(sshDir string) string {
	return filepath.Join(sshDir, sshSubDirName, sshKeyName)
}
