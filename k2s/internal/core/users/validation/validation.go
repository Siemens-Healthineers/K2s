// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package validation

import (
	"fmt"
	"log/slog"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
)

type userProvider interface {
	CurrentUser() (*users.OSUser, error)
}

type UserValidator struct {
	userProvider userProvider
}

func NewUserValidator(userProvider userProvider) *UserValidator {
	return &UserValidator{
		userProvider: userProvider,
	}
}

func (u *UserValidator) ValidateUser(user *users.OSUser) error {
	slog.Debug("Validating user", "name", user.Name(), "id", user.Id())

	currentUser, err := u.userProvider.CurrentUser()
	if err != nil {
		return fmt.Errorf("failed to determine current user: %w", err)
	}

	if user.Equals(currentUser) {
		return fmt.Errorf("cannot overwrite access of current user (name='%s', id='%s')", currentUser.Name(), currentUser.Id())
	}

	slog.Debug("User validated", "name", user.Name(), "id", user.Id())
	return nil
}
