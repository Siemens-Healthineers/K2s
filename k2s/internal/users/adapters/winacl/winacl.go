// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package winacl

import (
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/providers/winacl"
)

type ACLProvider struct{}

func NewACLProvider() *ACLProvider {
	return &ACLProvider{}
}

func (*ACLProvider) TransferFileOwnership(path string, user *users.OSUser) error {
	return winacl.TransferFileOwnership(path, user)
}
