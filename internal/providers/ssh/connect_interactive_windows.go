// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package ssh

func ConnectInteractively(options ConnectionOptions) error {
	return connectInteractively(options, "ssh.exe")
}
