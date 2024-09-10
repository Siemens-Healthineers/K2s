// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package nodes

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"

	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/internal/core/config"
)

type cmdExecutor interface {
	ExecuteCmd(name string, arg ...string) error
}

type sshExecutor interface {
	SetConfig(sshKeyPath string, remoteUser string, remoteHost string)
	Exec(cmd string) error
	ScpToRemote(source string, target string) error
	ScpFromRemote(source string, target string) error
}

type ControlPlane struct {
	ssh       sshExecutor
	name      string
	ipAddress string
}

const (
	sshKeyName           = "id_rsa"
	controlPlaneUserName = "remote"
)

func NewControlPlane(sshExecutor sshExecutor, cfg *config.Config, controlPlaneName string) (*ControlPlane, error) {
	controlePlaneCfg, found := lo.Find(cfg.Nodes, func(node config.NodeConfig) bool {
		return node.IsControlPlane
	})
	if !found {
		return nil, errors.New("could not find control-plane node config")
	}

	sshKeyPath := filepath.Join(cfg.Host.SshDir, controlPlaneName, sshKeyName)

	sshExecutor.SetConfig(sshKeyPath, controlPlaneUserName, controlePlaneCfg.IpAddress)

	return &ControlPlane{
		name:      controlPlaneName,
		ssh:       sshExecutor,
		ipAddress: controlePlaneCfg.IpAddress,
	}, nil
}

func (c *ControlPlane) Name() string {
	return c.name
}

func (c *ControlPlane) IpAddress() string {
	return c.ipAddress
}

func (c *ControlPlane) Exec(cmd string) error {
	slog.Debug("Exec cmd on control-plane")
	if err := c.ssh.Exec(cmd); err != nil {
		return fmt.Errorf("could not exec cmd on control-plane: %w", err)
	}
	return nil
}

func (c *ControlPlane) CopyTo(source string, target string) error {
	slog.Debug("Copying to control-plane")
	if err := c.ssh.ScpToRemote(source, target); err != nil {
		return fmt.Errorf("could not copy to control-plane: %w", err)
	}
	return nil
}

func (c *ControlPlane) CopyFrom(source string, target string) error {
	slog.Debug("Copying from control-plane")
	if err := c.ssh.ScpFromRemote(source, target); err != nil {
		return fmt.Errorf("could not copy from control-plane: %w", err)
	}
	return nil
}
