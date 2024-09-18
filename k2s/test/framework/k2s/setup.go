// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"errors"
	"os"
	"strings"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
)

type SetupInfo struct {
	Config      config.Config
	SetupConfig setupinfo.Config
	WinNodeName string
}

func CreateSetupInfo(installDir string) *SetupInfo {
	config, err := config.LoadConfig(installDir)
	Expect(err).ToNot(HaveOccurred())

	return &SetupInfo{
		Config: *config,
	}
}

func (si *SetupInfo) LoadSetupConfig() {
	setupConfig, err := setupinfo.ReadConfig(si.Config.Host.K2sConfigDir)
	Expect(err).ToNot(HaveOccurred())

	winNodeName, err := getWinNodeName(setupConfig.SetupName)
	Expect(err).ToNot(HaveOccurred())

	si.WinNodeName = winNodeName
	si.SetupConfig = *setupConfig
}

func GetWindowsNode(nodes config.Nodes) config.NodeConfig {
	for _, node := range nodes {
		if node.OsType == config.OsTypeWindows {
			GinkgoWriter.Println("Returning first Windows node found in config")

			return node
		}
	}

	Fail("No Windows node config found")

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
