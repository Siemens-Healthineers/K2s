// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build linux

package ssh

func ConnectInteractively(options ConnectionOptions) error {
	return connectInteractively(options, "ssh")
}
