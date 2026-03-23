// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package provider

import "errors"

// ErrNotSupported is returned when a provider method is not available on the
// current platform (e.g., Windows-only operations on Linux).
var ErrNotSupported = errors.New("operation not supported on this platform")

// NotSupportedError returns a formatted not-supported error with a reason.
func NotSupportedError(operation, reason string) error {
	return &UnsupportedOperationError{Operation: operation, Reason: reason}
}

// UnsupportedOperationError provides detailed information about why an
// operation is not available on the current platform.
type UnsupportedOperationError struct {
	Operation string
	Reason    string
}

func (e *UnsupportedOperationError) Error() string {
	return "'" + e.Operation + "' is not supported on this platform: " + e.Reason
}

func (e *UnsupportedOperationError) Is(target error) bool {
	return target == ErrNotSupported
}
