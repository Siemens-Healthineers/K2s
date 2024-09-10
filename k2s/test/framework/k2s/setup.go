// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"errors"
	"os"
	"strings"

	"github.com/onsi/ginkgo/v2"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
)

type SetupInfo struct {
	Config      config.Config
	SetupConfig setupinfo.Config
	WinNodeName string
}

func GetSetupInfo(installDir string) (*SetupInfo, error) {
	config, err := config.LoadConfig(installDir)
	if err != nil {
		return nil, err
	}

	setupConfig, err := setupinfo.ReadConfig(config.Host.K2sConfigDir)
	if err != nil {
		return nil, err
	}

	winNodeName, err := getWinNodeName(setupConfig.SetupName)
	if err != nil {
		return nil, err
	}

	return &SetupInfo{
		WinNodeName: winNodeName,
		Config:      *config,
		SetupConfig: *setupConfig,
	}, nil
}

func GetWindowsNode(nodes config.Nodes) config.NodeConfig {
	for _, node := range nodes {
		if node.OsType == config.OsTypeWindows {
			ginkgo.GinkgoWriter.Println("Returning first Windows node found in config")

			return node
		}
	}

	ginkgo.Fail("No Windows node config found")

	return config.NodeConfig{}
}

func getWinNodeName(setupName setupinfo.SetupName) (string, error) {
	switch setupName {
	case setupinfo.SetupNamek2s:
		name, err := os.Hostname()
		if err != nil {
			return "", err
		}
		return strings.ToLower(name), nil
	case setupinfo.SetupNameMultiVMK8s:
		return "winnode", nil
	default:
		return "", errors.New("no setup type defined")
	}
}
