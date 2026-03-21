// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package powershell

// PsCmd is the PowerShell executable name on Linux (PowerShell Core).
// On Linux, PowerShell Core ("pwsh") is used when PS scripts need to run
// (e.g., inside a Windows VM via remoting). For native Linux orchestration,
// the Go CLI calls bash/native commands directly instead.
const PsCmd = "pwsh"
