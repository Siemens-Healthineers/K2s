// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package winusers

import (
	"errors"
	"fmt"
	"os"
	"os/user"
	"path/filepath"
	"strings"
)

type User struct {
	id      string
	name    string
	homeDir string
}

type winUserProvider struct{}

const (
	systemAccountName     = "SYSTEM"
	systemAccountFullName = "NT AUTHORITY\\" + systemAccountName
	systemAccountId       = "S-1-5-18"
)

var systemAccountHomeDir = filepath.Join(os.Getenv("SYSTEMROOT"), "System32\\config\\systemprofile")

func NewWinUserProvider() *winUserProvider {
	return &winUserProvider{}
}

func NewUser(id, name, homeDir string) *User {
	return &User{
		id:      id,
		name:    name,
		homeDir: homeDir,
	}
}

func (*winUserProvider) FindByName(name string) (*User, error) {
	if isSystemAccountName(name) {
		return NewUser(systemAccountId, systemAccountFullName, systemAccountHomeDir), nil
	}

	found, err := user.Lookup(name)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by name '%s'", name)
	}

	return NewUser(found.Uid, found.Username, found.HomeDir), nil
}

func (*winUserProvider) FindById(id string) (*User, error) {
	if isSystemAccountId(id) {
		return NewUser(systemAccountId, systemAccountFullName, systemAccountHomeDir), nil
	}

	found, err := user.LookupId(id)
	if err != nil {
		return nil, fmt.Errorf("could not find Windows user by id '%s'", id)
	}

	return NewUser(found.Uid, found.Username, found.HomeDir), nil
}

func (*winUserProvider) Current() (*User, error) {
	current, err := user.Current()
	if err != nil {
		return nil, errors.New("could not determine current Windows user")
	}

	return NewUser(current.Uid, current.Username, current.HomeDir), nil
}

func (u *User) Id() string {
	return u.id
}

func (u *User) Name() string {
	return u.name
}

func (u *User) HomeDir() string {
	return u.homeDir
}

func isSystemAccountName(name string) bool {
	return strings.EqualFold(name, systemAccountName) || strings.EqualFold(name, systemAccountFullName)
}

func isSystemAccountId(id string) bool {
	return strings.EqualFold(id, systemAccountId)
}
