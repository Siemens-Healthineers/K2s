// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import "fmt"

// psFailure mirrors common.CmdFailure for PS structured result deserialization.
// Defined locally to avoid circular imports with cmd/common.
type psFailure struct {
	Severity          uint8  `json:"severity"`
	Code              string `json:"code"`
	Message           string `json:"message"`
	SuppressCliOutput bool   `json:"suppressCliOutput"`
}

func (f *psFailure) Error() string {
	return fmt.Sprintf("[%s] %s", f.Code, f.Message)
}

// psCmdResult mirrors common.CmdResult for PS structured result deserialization.
type psCmdResult struct {
	Failure *psFailure `json:"error"`
}

// checkFailure returns the failure as an error if present, nil otherwise.
func (r *psCmdResult) checkFailure() error {
	if r.Failure != nil {
		return r.Failure
	}
	return nil
}
