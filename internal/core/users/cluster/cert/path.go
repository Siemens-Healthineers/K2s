// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package cert

import "path/filepath"

func DetermineLocalCertPaths(localDir string, remoteCmd RemoteCertCmd) (certPath, keyPath string) {
	tempDirName := filepath.Base(remoteCmd.TempDir)
	certPath = filepath.Join(localDir, tempDirName, remoteCmd.CertFileName)
	keyPath = filepath.Join(localDir, tempDirName, remoteCmd.KeyFileName)
	return
}
