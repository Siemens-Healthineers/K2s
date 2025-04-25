// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package k2s

import (
	"errors"
	"os"
	"strings"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/clusterconfig"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
)

type SetupInfo struct {
	Config        config.ConfigReader
	SetupConfig   setupinfo.Config
	ClusterConfig *clusterconfig.Cluster
	WinNodeName   string
}

func CreateSetupInfo(installDir string) *SetupInfo {
	config, err := config.LoadConfig(installDir)
	Expect(err).ToNot(HaveOccurred())

	return &SetupInfo{
		Config: config,
	}
}

func (si *SetupInfo) LoadSetupConfig() {
	setupConfig, err := setupinfo.ReadConfig(si.Config.Host().K2sConfigDir())
	Expect(err).ToNot(HaveOccurred())

	winNodeName, err := getWinNodeName(setupConfig.SetupName)
	Expect(err).ToNot(HaveOccurred())

	si.WinNodeName = winNodeName
	si.SetupConfig = *setupConfig
}

func (si *SetupInfo) LoadClusterConfig() {
	clusterConfig, err := clusterconfig.Read(si.Config.Host().K2sConfigDir())
	Expect(err).ToNot(HaveOccurred())

	if clusterConfig != nil {
		si.ClusterConfig = clusterConfig
	}
}

func (si *SetupInfo) GetProxyForNode(nodeName string) string {
	proxy := "http://172.19.1.1:8181"

	if si.ClusterConfig != nil {
		for _, n := range si.ClusterConfig.Nodes {
			if n.Name == nodeName && n.Proxy != "" {
				proxy = n.Proxy
				break
			}
		}
	}

	return proxy
}

func getWinNodeName(setupName setupinfo.SetupName) (string, error) {
	switch setupName {
	case setupinfo.SetupNamek2s:
		name, err := os.Hostname()
		if err != nil {
			return "", err
		}
		return strings.ToLower(name), nil
	default:
		return "", errors.New("no setup type defined")
	}
}
