// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package os

import (
	o "os"
)

type DirProvider struct {
}

func NewDirProvider() DirProvider {
	return DirProvider{}
}

func (d DirProvider) GetUserHomeDir() (string, error) {
	return o.UserHomeDir()
}

func CreateDirIfNotExisting(dir string) error {
	_, err := o.Stat(dir)
	if !o.IsNotExist(err) {
		return err
	}

	if err = o.MkdirAll(dir, o.ModePerm); err != nil {
		return err
	}

	return nil
}
