// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package clusterconfig

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/internal/json"
)

type NodeType string
type Role string
type OS string

type Node struct {
	Name      string   `json:"Name"`
	IpAddress string   `json:"IpAddress"`
	Proxy     string   `json:"Proxy"`
	Username  string   `json:"Username"`
	NodeType  NodeType `json:"NodeType"`
	Role      Role     `json:"Role"`
	OS        OS       `json:"OS"`
}

// Cluster represents the JSON structure.
type Cluster struct {
	Nodes []Node `json:"nodes"`
}

const (
	NodeTypeHost       NodeType = "HOST"
	NodeTypeVMNew      NodeType = "VM-NEW"
	NodeTypeVMExisting NodeType = "VM-EXISTING"

	RoleWorker       Role = "worker"
	RoleControlPlane Role = "control-plane"

	OsTypeWindows = "windows"
	OsTypeLinux   = "linux"

	ConfigFileName = "cluster.json"
)

func ConfigPath(configDir string) string {
	return filepath.Join(configDir, ConfigFileName)
}

func Read(configDir string) (*Cluster, error) {
	configPath := ConfigPath(configDir)

	config, err := json.FromFile[Cluster](configPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			slog.Info("Cluster config file not found, assuming no additional nodes present", "path", configPath)

			return nil, nil
		}
		return nil, fmt.Errorf("error occurred while loading cluster config file: %w", err)
	}

	return config, nil
}

func GetNodeDirectory(nodeType string) string {
	switch NodeType(nodeType) {
	case NodeTypeHost:
		return "bare-metal"
	case NodeTypeVMNew:
		return "hyper-v-vm\\new-vm"
	case NodeTypeVMExisting:
		return "hyper-v-vm\\existing-vm"
	default:
		return "unknown-node-type"
	}
}
