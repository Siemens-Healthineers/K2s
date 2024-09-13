// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

func CreateK2sUserName(winUserName string) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(winUserName, " ", "-"), "\\", "-")

	return common.K2sPrefix + beautifiedUsername
}
