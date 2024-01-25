// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package load

import (
	d "k2s/config/defs"
	"k2s/setupinfo"

	"k8s.io/klog/v2"
)

type FileReader interface {
	Read(filename string) ([]byte, error)
	IsFileNotExist(err error) bool
}

type JsonUnmarshaller interface {
	Unmarshal(data []byte, v any) error
}

type ConfigLoader struct {
	fileReader       FileReader
	jsonUnmarshaller JsonUnmarshaller
}

func NewConfigLoader(fileReader FileReader, jsonUnmarshaller JsonUnmarshaller) ConfigLoader {
	return ConfigLoader{
		fileReader:       fileReader,
		jsonUnmarshaller: jsonUnmarshaller,
	}
}

func (cl ConfigLoader) Load(filePath string) (*d.Config, error) {
	return load[d.Config](filePath, cl)
}

func (cl ConfigLoader) LoadForSetup(filePath string) (*d.SetupConfig, error) {
	config, err := load[d.SetupConfig](filePath, cl)

	if cl.fileReader.IsFileNotExist(err) {
		klog.V(2).ErrorS(err, "setup config file not found, assuming setup is not installed")

		return nil, setupinfo.ErrNotInstalled
	}

	return config, err
}

func load[T any](filePath string, cl ConfigLoader) (v *T, err error) {
	binaries, err := cl.fileReader.Read(filePath)
	if err != nil {
		return nil, err
	}

	err = cl.jsonUnmarshaller.Unmarshal(binaries, &v)
	if err != nil {
		return nil, err
	}

	return v, nil
}
