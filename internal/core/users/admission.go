// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"

	"github.com/siemens-healthineers/k2s/internal/contracts/users"
)

type userValidator interface {
	ValidateUser(user *users.OSUser) error
}

type k2sUserNameProvider interface {
	DetermineK2sUserName(user *users.OSUser) string
}

type admission interface {
	GrantAccess(user *users.OSUser, k2sUserName string) error
}

type UserAdmission struct {
	userValidator         userValidator
	k2sUserNameProvider   k2sUserNameProvider
	controlPlaneAdmission admission
	clusterAdmission      admission
}

func NewUserAdmission(userValidator userValidator, k2sUserNameProvider k2sUserNameProvider, controlPlaneAdmission, clusterAdmission admission) *UserAdmission {
	return &UserAdmission{
		userValidator:         userValidator,
		k2sUserNameProvider:   k2sUserNameProvider,
		controlPlaneAdmission: controlPlaneAdmission,
		clusterAdmission:      clusterAdmission,
	}
}

func (u *UserAdmission) Add(user *users.OSUser) error {
	slog.Debug("Adding user to K2s", "name", user.Name(), "id", user.Id())

	if err := u.userValidator.ValidateUser(user); err != nil {
		return fmt.Errorf("failed to validate user '%s': %w", user.Name(), err)
	}

	k2sUserName := u.k2sUserNameProvider.DetermineK2sUserName(user)

	allErrors := []error{nil, nil}
	tasks := sync.WaitGroup{}
	tasks.Add(len(allErrors))

	go func() {
		defer tasks.Done()
		if err := u.controlPlaneAdmission.GrantAccess(user, k2sUserName); err != nil {
			allErrors[0] = fmt.Errorf("failed to grant user control-plane access: %w", err)
		}
	}()

	go func() {
		defer tasks.Done()
		if err := u.clusterAdmission.GrantAccess(user, k2sUserName); err != nil {
			allErrors[1] = fmt.Errorf("failed to grant user Kubernetes access: %w", err)
		}
	}()

	tasks.Wait()

	return errors.Join(allErrors...)
}
