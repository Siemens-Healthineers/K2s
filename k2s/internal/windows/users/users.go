// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

type winUser struct {
	userId   string
	username string
	homeDir  string
}

const (
	systemAccountName     = "SYSTEM"
	systemAccountFullName = "NT AUTHORITY\\" + systemAccountName
	systemAccountId       = "S-1-5-18"
)

var systemAccountHomeDir = filepath.Join(os.Getenv("SYSTEMROOT"), "System32\\config\\systemprofile")

func FindByName(name string) (*winUser, error) {
	if isSystemAccountName(name) {
		return newSystemUser(), nil
	}

	found, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by name '%s'", name)
	}

	return newWinUser(found), nil
}

func FindById(id string) (*winUser, error) {
	if isSystemAccountId(id) {
		return newSystemUser(), nil
	}

	found, err := user.LookupId(id)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by id '%s'", id)
	}

	return newWinUser(found), nil
}

func Current() (*winUser, error) {
	current, err := user.Current()
	if err != nil {
		return nil, errors.New("could not determine current Windows user")
	}

	return newWinUser(current), nil
}

func (u *winUser) UserId() string {
	return u.userId
}

func (u *winUser) Username() string {
	return u.username
}

func (u *winUser) HomeDir() string {
	return u.homeDir
}

func isSystemAccountName(name string) bool {
	return strings.EqualFold(name, systemAccountName) || strings.EqualFold(name, systemAccountFullName)
}

func isSystemAccountId(id string) bool {
	return strings.EqualFold(id, systemAccountId)
}

func newSystemUser() *winUser {
	return &winUser{
		userId:   systemAccountId,
		username: systemAccountFullName,
		homeDir:  systemAccountHomeDir,
	}
}

func newWinUser(u *user.User) *winUser {
	return &winUser{
		userId:   u.Uid,
		username: u.Username,
		homeDir:  u.HomeDir,
	}
}
