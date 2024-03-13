// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package path

import (
	"path/filepath"
	"strings"
)

type DirProvider interface {
	GetUserHomeDir() (string, error)
}

type SetupConfigPathBuilder struct {
	dirProvider DirProvider
}

func NewSetupConfigPathBuilder(dirProvider DirProvider) SetupConfigPathBuilder {
	return SetupConfigPathBuilder{
		dirProvider: dirProvider,
	}
}

func (s SetupConfigPathBuilder) Build(configDir string, configFileName string) (string, error) {
	if strings.HasPrefix(configDir, "~/") {
		homeDir, err := s.dirProvider.GetUserHomeDir()
		if err != nil {
			return "", err
		}

		configDir = filepath.Join(homeDir, configDir[2:])
	}

	result := filepath.Join(configDir, configFileName)

	return result, nil
}
