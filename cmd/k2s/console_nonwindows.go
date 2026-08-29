// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build !windows

package main

// enableVirtualTerminalProcessing is a no-op on non-Windows platforms, where
// terminals handle ANSI/VT escape sequences natively.
func enableVirtualTerminalProcessing() {}
