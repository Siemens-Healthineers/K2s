// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package acl

import (
	"fmt"
	"os"
	"strconv"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
)

func TransferFileOwnership(path string, targetUser *users.OSUser) error {
	uid, err := strconv.Atoi(targetUser.Id())
	if err != nil {
		return fmt.Errorf("invalid UID '%s': %w", targetUser.Id(), err)
	}
	return os.Chown(path, uid, -1)
}
