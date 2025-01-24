// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
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

func (a *winUserAdder) Add(user common.User, currentUserName string) error {
	slog.Debug("Adding user", "name", user.Name(), "home-dir", user.HomeDir())

	k2sUserName := a.createK2sUserName(user.Name())

	var controlPlaneErr, k8sErr error
	tasks := sync.WaitGroup{}
	tasks.Add(2)

	go func() {
		defer tasks.Done()
		if err := a.controlPlaneAccess.GrantAccessTo(user, currentUserName, k2sUserName); err != nil {
			controlPlaneErr = fmt.Errorf("cannot grant user SSH access to control-plane: %w", err)
		}
	}()

	go func() {
		defer tasks.Done()
		if err := a.k8sAccess.GrantAccessTo(user, k2sUserName); err != nil {
			k8sErr = fmt.Errorf("cannot grant user K8s access: %w", err)
		}
	}()

	tasks.Wait()

	return errors.Join(controlPlaneErr, k8sErr)
}
