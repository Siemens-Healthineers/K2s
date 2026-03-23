// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build windows

package provider

import (
	"fmt"
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	k2sos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

type windowsAddonProvider struct {
	installDir string
	stdWriter  k2sos.StdWriter
}

func newWindowsAddonProvider(cfg ProviderConfig) *windowsAddonProvider {
	return &windowsAddonProvider{
		installDir: cfg.InstallDir,
		stdWriter:  cfg.StdWriter,
	}
}

func (p *windowsAddonProvider) Enable(cfg AddonEnableConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", cfg.Name, "Enable.ps1"))

	var params string
	for key, val := range cfg.Params {
		params += fmt.Sprintf(" -%s '%s'", key, val)
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) Disable(cfg AddonDisableConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", cfg.Name, "Disable.ps1"))

	var params string
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) List(cfg AddonListConfig) (*AddonListResult, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Get-Status.ps1"))

	type psAddon struct {
		Name    string `json:"name"`
		Enabled bool   `json:"enabled"`
	}
	type psResult struct {
		psCmdResult
		Addons []psAddon `json:"addons"`
	}

	var params string
	if cfg.ShowOutput {
		params = " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return nil, err
	}
	if err := result.checkFailure(); err != nil {
		return nil, err
	}

	listResult := &AddonListResult{}
	for _, a := range result.Addons {
		listResult.Addons = append(listResult.Addons, AddonInfo{
			Name:    a.Name,
			Enabled: a.Enabled,
		})
	}

	return listResult, nil
}

func (p *windowsAddonProvider) Status(cfg AddonStatusConfig) (*AddonStatusResult, error) {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Get-Status.ps1"))

	type psProp struct {
		Name  string `json:"name"`
		Value string `json:"value"`
		Okay  bool   `json:"okay"`
	}
	type psAddon struct {
		Name    string   `json:"name"`
		Enabled bool     `json:"enabled"`
		Props   []psProp `json:"props"`
	}
	type psResult struct {
		psCmdResult
		Addons []psAddon `json:"addons"`
	}

	var params string
	if cfg.Name != "" {
		params += " -Name " + cfg.Name
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return nil, err
	}
	if err := result.checkFailure(); err != nil {
		return nil, err
	}

	statusResult := &AddonStatusResult{}
	for _, a := range result.Addons {
		info := AddonStatusInfo{
			Name:    a.Name,
			Enabled: a.Enabled,
		}
		for _, prop := range a.Props {
			info.Props = append(info.Props, AddonStatusProp{
				Name:  prop.Name,
				Value: prop.Value,
				Okay:  prop.Okay,
			})
		}
		statusResult.Addons = append(statusResult.Addons, info)
	}

	return statusResult, nil
}

func (p *windowsAddonProvider) Export(cfg AddonExportConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Export.ps1"))

	var params string
	if cfg.OutputDir != "" {
		params += fmt.Sprintf(" -ExportDir '%s'", cfg.OutputDir)
	}
	if cfg.Name != "" {
		params += " -Name " + cfg.Name
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}

func (p *windowsAddonProvider) Import(cfg AddonImportConfig) error {
	scriptPath := utils.FormatScriptFilePath(filepath.Join(p.installDir, "addons", "Import.ps1"))

	var params string
	if cfg.InputDir != "" {
		params += fmt.Sprintf(" -ImportDir '%s'", cfg.InputDir)
	}
	if cfg.Name != "" {
		params += " -Name " + cfg.Name
	}
	if cfg.ShowOutput {
		params += " -ShowLogs"
	}

	result, err := powershell.ExecutePsWithStructuredResult[*psCmdResult](scriptPath+params, "CmdResult", p.stdWriter)
	if err != nil {
		return err
	}
	return result.checkFailure()
}
