// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host

// SystemDrive returns hard-coded 'C:\' drive string instead of the actual system drive, because some containers are also hard-coded to this drive.
//
// Note: This string has already the backslash '\' attached, because Go's filepath.Join() would otherwise not be able to correctly join the drive and other path components
// (see https://github.com/golang/go/issues/26953).
func SystemDrive() string {
	return "C:\\"
}
