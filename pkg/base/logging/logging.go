//// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
//// SPDX-License-Identifier:   MIT

package logging

import (
	"base/system"
	"path/filepath"
)

func RootLogDir() string {
	return filepath.Join(system.SystemDrive(), "var", "log")
}
