// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package defs

type ValidationError string

type SetupInfo struct {
	Version         *string `json:"version"`
	Name            *string `json:"name"`
	ValidationError *string `json:"validationError"`
	LinuxOnly       *bool   `json:"linuxOnly"`
}

const (
	ErrNotInstalled       ValidationError = "not-installed"
	ErrNoClusterAvailable ValidationError = "no-cluster"
)
