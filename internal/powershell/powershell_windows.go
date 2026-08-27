// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package powershell

// PsCmd is the PowerShell executable name on Windows (Windows PowerShell 5.1).
const PsCmd = "powershell"

// platformGuard is a no-op on Windows where PowerShell 5.1 is always available.
func platformGuard() error {
	return nil
}
