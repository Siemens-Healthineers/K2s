// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package naming

import (
	"strings"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
)

func DetermineK2sUserName(user *users.OSUser) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(user.Name(), " ", "-"), "\\", "-")

	return definitions.K2sUsersPrefix + beautifiedUsername
}
