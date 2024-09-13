// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type controlPlaneAccess interface {
	GrantAccessTo(user common.User, currentUserName, k2sUserName string) (err error)
}

type k8sAccess interface {
	GrantAccessTo(user common.User, k2sUserName string) error
}

type winUserAdder struct {
	controlPlaneAccess controlPlaneAccess
	k8sAccess          k8sAccess
	createK2sUserName  func(winUserName string) string
}

func NewWinUserAdder(controlPlaneAccess controlPlaneAccess, k8sAccess k8sAccess, createK2sUserName func(winUserName string) string) *winUserAdder {
	return &winUserAdder{
		controlPlaneAccess: controlPlaneAccess,
		k8sAccess:          k8sAccess,
		createK2sUserName:  createK2sUserName,
	}
}

func (a *winUserAdder) Add(user common.User, currentUserName string) (err error) {
	slog.Debug("Adding user", "name", user.Name(), "home-dir", user.HomeDir())

	k2sUserName := a.createK2sUserName(user.Name())

	tasks := sync.WaitGroup{}
	tasks.Add(2)

	go func() {
		defer tasks.Done()
		if innerErr := a.controlPlaneAccess.GrantAccessTo(user, currentUserName, k2sUserName); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("cannot grant user SSH access to control-plane: %w", innerErr))
		}
	}()

	go func() {
		defer tasks.Done()
		if innerErr := a.k8sAccess.GrantAccessTo(user, k2sUserName); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("cannot grant user K8s access: %w", innerErr))
		}
	}()

	tasks.Wait()

	return err
}
