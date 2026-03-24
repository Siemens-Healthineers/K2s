// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

<<<<<<< HEAD
=======
import "fmt"

>>>>>>> main
// psFailure mirrors common.CmdFailure for PS structured result deserialization.
// Defined locally to avoid circular imports with cmd/common.
type psFailure struct {
	Severity          uint8  `json:"severity"`
	Code              string `json:"code"`
	Message           string `json:"message"`
	SuppressCliOutput bool   `json:"suppressCliOutput"`
}

<<<<<<< HEAD
=======
func (f *psFailure) Error() string {
	return fmt.Sprintf("[%s] %s", f.Code, f.Message)
}

>>>>>>> main
// psCmdResult mirrors common.CmdResult for PS structured result deserialization.
type psCmdResult struct {
	Failure *psFailure `json:"error"`
}

<<<<<<< HEAD
// checkFailure returns the failure as a *ProviderFailure error if present, nil otherwise.
// ProviderFailure is the exported error type that the main CLI error handler recognizes.
func (r *psCmdResult) checkFailure() error {
	if r.Failure != nil {
		return &ProviderFailure{
			Severity:          FailureSeverity(r.Failure.Severity),
			Code:              r.Failure.Code,
			Message:           r.Failure.Message,
			SuppressCliOutput: r.Failure.SuppressCliOutput,
		}
=======
// checkFailure returns the failure as an error if present, nil otherwise.
func (r *psCmdResult) checkFailure() error {
	if r.Failure != nil {
		return r.Failure
>>>>>>> main
	}
	return nil
}
