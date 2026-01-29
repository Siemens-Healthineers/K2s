// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package naming

import (
	"strings"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/definitions"
)

type K2sUserNameProvider struct{}

func NewK2sUserNameProvider() *K2sUserNameProvider {
	return &K2sUserNameProvider{}
}

func (*K2sUserNameProvider) DetermineK2sUserName(user *users.OSUser) string {
	beautifiedUsername := strings.ReplaceAll(strings.ReplaceAll(user.Name(), " ", "-"), "\\", "-")

	return definitions.K2sUsersPrefix + beautifiedUsername
}
