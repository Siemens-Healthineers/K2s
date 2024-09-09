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

type WinUser struct {
	UserId   string
	GroupId  string
	Username string
	HomeDir  string
}

const (
	systemAccountName     = "SYSTEM"
	systemAccountFullName = "NT AUTHORITY\\" + systemAccountName
	systemAccountId       = "S-1-5-18"
)

var systemAccountHomeDir = filepath.Join(os.Getenv("SYSTEMROOT"), "System32\\config\\systemprofile")

func FindByName(name string) (*WinUser, error) {
	if isSystemAccountName(name) {
		return newSystemUser(), nil
	}

	found, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by name '%s'", name)
	}

	return newWinUser(found), nil
}

func FindById(id string) (*WinUser, error) {
	if isSystemAccountId(id) {
		return newSystemUser(), nil
	}

	found, err := user.LookupId(id)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by id '%s'", id)
	}

	return newWinUser(found), nil
}

func Current() (*WinUser, error) {
	current, err := user.Current()
	if err != nil {
		return nil, errors.New("could not determine current Windows user")
	}

	return newWinUser(current), nil
}

func isSystemAccountName(name string) bool {
	return strings.EqualFold(name, systemAccountName) || strings.EqualFold(name, systemAccountFullName)
}

func isSystemAccountId(id string) bool {
	return strings.EqualFold(id, systemAccountId)
}

func newSystemUser() *WinUser {
	return &WinUser{
		UserId:   systemAccountId,
		Username: systemAccountFullName,
		HomeDir:  systemAccountHomeDir,
	}
}

func newWinUser(u *user.User) *WinUser {
	return &WinUser{
		UserId:   u.Uid,
		GroupId:  u.Gid,
		Username: u.Username,
		HomeDir:  u.HomeDir,
	}
}
