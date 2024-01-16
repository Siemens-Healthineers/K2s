// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package tz

import (
	"embed"
	"os"
	"path/filepath"
	"syscall"
)

var (
	//go:embed embed/*.xml
	embeddedTimezoneConfig embed.FS

	kubedir = filepath.Join(os.Getenv("USERPROFILE"), ".kube")
)

const (
	TimezoneConfigFile = "windowsZones.xml"
)

type ConfigWorkspace interface {
	CreateHandle() (ConfigWorkspaceHandle, error)
}

type ConfigWorkspaceHandle interface {
	Release() error
}

type fileHandler interface {
	CopyTo(newFile, originalFile string) error
	Remove(file string) error
}

type timezoneConfigHandler struct{}

type TimezoneConfigWorkspaceHandle struct {
	timezoneConfigFilePath string
	fileHandler            fileHandler
}

type TimezoneConfigWorkspace struct {
	kubeDir     string
	fileHandler fileHandler
}

func (tzch *timezoneConfigHandler) createDirectoryIfNotExist(directory string) error {
	_, err := os.Stat(directory)
	if err != nil {
		if os.IsNotExist(err) {
			err := os.MkdirAll(directory, 0777)
			if err != nil {
				return err
			}
		} else {
			return err
		}
	}
	return nil
}

func (tzch *timezoneConfigHandler) CopyTo(newFile, orginalFile string) error {
	embeddedFileContent, err := embeddedTimezoneConfig.ReadFile(orginalFile)
	if err != nil {
		return err
	}

	pathWithDirectoryOnly := filepath.Dir(newFile)
	err = tzch.createDirectoryIfNotExist(pathWithDirectoryOnly)
	if err != nil {
		return err
	}

	// Copy the contents of the embedded file to the new file.
	err = os.WriteFile(newFile, []byte(embeddedFileContent), 0644)
	if err != nil {
		return err
	}

	return nil
}

func (tzch *timezoneConfigHandler) Remove(file string) error {
	err := syscall.Unlink(file)
	if err != nil {
		return err
	}
	return nil
}

func NewTimezoneConfigWorkspace() (ConfigWorkspace, error) {
	fileHandler := &timezoneConfigHandler{}

	return &TimezoneConfigWorkspace{
		kubeDir:     kubedir,
		fileHandler: fileHandler,
	}, nil
}

func (tcws *TimezoneConfigWorkspace) CreateHandle() (ConfigWorkspaceHandle, error) {
	embeddedTzFp := "embed/" + TimezoneConfigFile
	tzFp := tcws.kubeDir + "\\" + TimezoneConfigFile

	err := tcws.fileHandler.CopyTo(tzFp, embeddedTzFp)
	if err != nil {
		return nil, err
	}

	return &TimezoneConfigWorkspaceHandle{
		timezoneConfigFilePath: tzFp,
		fileHandler:            tcws.fileHandler,
	}, nil
}

func (tcwh *TimezoneConfigWorkspaceHandle) Release() error {
	err := tcwh.fileHandler.Remove(tcwh.timezoneConfigFilePath)
	if err != nil {
		return err
	}
	return nil
}
