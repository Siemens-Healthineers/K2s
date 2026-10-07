// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package effectiveconfig

import "os"

func restrictFile(path string) error {
	return os.Chmod(path, restrictedFileMode)
}

func atomicReplace(source string, target string) error {
	return os.Rename(source, target)
}
