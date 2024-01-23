// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

type ValidationError string

type SetupInfo struct {
	Version         *string          `json:"version"`
	Name            *string          `json:"name"`
	ValidationError *ValidationError `json:"validationError"`
	LinuxOnly       *bool            `json:"linuxOnly"`
}

const (
	ErrNotInstalled       ValidationError = "not-installed"
	ErrNoClusterAvailable ValidationError = "no-cluster"
)
