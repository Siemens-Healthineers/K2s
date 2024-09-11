// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"log/slog"
	"sync"
)

type accessGranter interface {
	GrantAccess(winUser WinUser, k2sUserName string) error
}

type winUserAdder struct {
	sshAccessGranter  accessGranter
	k8sAccessGranter  accessGranter
	createK2sUserName func(winUserName string) string
}

func NewWinUserAdder(sshAccessGranter accessGranter, k8sAccessGranter accessGranter, createK2sUserName func(winUserName string) string) *winUserAdder {
	return &winUserAdder{
		sshAccessGranter:  sshAccessGranter,
		k8sAccessGranter:  k8sAccessGranter,
		createK2sUserName: createK2sUserName,
	}
}

func (a *winUserAdder) Add(winUser WinUser) (err error) {
	slog.Debug("Adding Windows user", "username", winUser.Username(), "id", winUser.UserId(), "homedir", winUser.HomeDir())

	k2sUserName := a.createK2sUserName(winUser.Username())

	tasks := sync.WaitGroup{}
	tasks.Add(2)

	go func() {
		defer tasks.Done()
		if innerErr := a.sshAccessGranter.GrantAccess(winUser, k2sUserName); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("cannot grant Windows user SSH access to control-plane: %w", innerErr))
		}
	}()

	go func() {
		defer tasks.Done()
		if innerErr := a.k8sAccessGranter.GrantAccess(winUser, k2sUserName); innerErr != nil {
			err = errors.Join(err, fmt.Errorf("cannot grant Windows user K8s access: %w", innerErr))
		}
	}()

	tasks.Wait()

	return err
}
