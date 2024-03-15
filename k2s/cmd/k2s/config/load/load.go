// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	"log/slog"

	d "github.com/siemens-healthineers/k2s/cmd/k2s/config/defs"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

type configLoader struct {
	readFileFunc       func(filename string) ([]byte, error)
	unmarshalFunc      func(data []byte, v any) error
	isFileNotExistFunc func(err error) bool
}

func NewConfigLoader(
	readFileFunc func(filename string) ([]byte, error),
	isFileNotExistFunc func(err error) bool,
	unmarshalFunc func(data []byte, v any) error) configLoader {
	return configLoader{
		readFileFunc:       readFileFunc,
		unmarshalFunc:      unmarshalFunc,
		isFileNotExistFunc: isFileNotExistFunc,
	}
}

func (cl configLoader) Load(filePath string) (*d.Config, error) {
	return load[d.Config](filePath, cl)
}

func (cl configLoader) LoadForSetup(filePath string) (*d.SetupConfig, error) {
	config, err := load[d.SetupConfig](filePath, cl)

	if cl.isFileNotExistFunc(err) {
		slog.Info("Setup config file not found, assuming setup is not installed", "error", err, "path", filePath)

		return nil, setupinfo.ErrSystemNotInstalled
	}

	return config, err
}

func load[T any](filePath string, cl configLoader) (v *T, err error) {
	binaries, err := cl.readFileFunc(filePath)
	if err != nil {
		return nil, err
	}

	err = cl.unmarshalFunc(binaries, &v)
	if err != nil {
		return nil, err
	}

	return v, nil
}
