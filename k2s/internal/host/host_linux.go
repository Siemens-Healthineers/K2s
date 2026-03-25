// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package host

// SystemDrive returns the filesystem root on Linux.
func SystemDrive() string {
	return "/"
}

// K2sConfigDir returns the K2s configuration/state directory on Linux.
func K2sConfigDir() string {
	return "/var/lib/k2s"
}
