// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"strings"
)

func CreateK2sUserName(winUserName string) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(winUserName, " ", "-"), "\\", "-")

	return k2sPrefix + beautifiedUsername
}
