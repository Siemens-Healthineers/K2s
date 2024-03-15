// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package path

import (
	"path/filepath"
	"strings"
)

type SetupConfigPathBuilder struct {
	getUserHomeDirFunc func() (string, error)
}

func NewSetupConfigPathBuilder(getUserHomeDirFunc func() (string, error)) SetupConfigPathBuilder {
	return SetupConfigPathBuilder{
		getUserHomeDirFunc: getUserHomeDirFunc,
	}
}

func (s SetupConfigPathBuilder) Build(configDir string, configFileName string) (string, error) {
	if strings.HasPrefix(configDir, "~/") {
		homeDir, err := s.getUserHomeDirFunc()
		if err != nil {
			return "", err
		}

		configDir = filepath.Join(homeDir, configDir[2:])
	}

	result := filepath.Join(configDir, configFileName)

	return result, nil
}
