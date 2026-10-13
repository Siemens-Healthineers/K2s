// SPDX-FileCopyrightText:  © 2026 The K2s Authors
// SPDX-License-Identifier:   MIT

//go:build !windows

package main

// enableVirtualTerminalProcessing is a no-op on non-Windows platforms, where
// terminals handle ANSI/VT escape sequences natively.
func enableVirtualTerminalProcessing() {}
