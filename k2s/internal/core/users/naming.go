// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

func CreateK2sUserName(userName string) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(userName, " ", "-"), "\\", "-")

	return common.K2sPrefix + beautifiedUsername
}
