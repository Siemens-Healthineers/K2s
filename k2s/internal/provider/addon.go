// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package provider

// AddonProvider abstracts addon management operations.
// On Windows: delegates to PowerShell scripts (Enable.ps1, Disable.ps1, etc.).
// On Linux: reads addon.manifest.yaml and applies manifests via kubectl directly.
type AddonProvider interface {
	// Enable enables an addon with the given parameters.
	Enable(config AddonEnableConfig) error

	// Disable disables an addon.
	Disable(config AddonDisableConfig) error

	// List returns all available addons and their status.
	List(config AddonListConfig) (*AddonListResult, error)

	// Status returns the status of specific or all addons.
	Status(config AddonStatusConfig) (*AddonStatusResult, error)

	// Export exports addon state for offline transfer.
	Export(config AddonExportConfig) error

	// Import imports addon state from an offline package.
	Import(config AddonImportConfig) error
}

// AddonEnableConfig holds parameters for enabling an addon.
type AddonEnableConfig struct {
	Name       string
	Params     map[string]string // Dynamic parameters from addon.manifest.yaml flags
	ShowOutput bool
}

// AddonDisableConfig holds parameters for disabling an addon.
type AddonDisableConfig struct {
	Name       string
	ShowOutput bool
}

// AddonListConfig holds parameters for listing addons.
type AddonListConfig struct {
	ShowOutput bool
}

// AddonListResult holds the list of available addons.
type AddonListResult struct {
	Addons []AddonInfo
}

// AddonInfo holds information about a single addon.
type AddonInfo struct {
	Name        string
	Enabled     bool
	Description string
}

// AddonStatusConfig holds parameters for querying addon status.
type AddonStatusConfig struct {
	Name       string // Empty means all addons
	ShowOutput bool
}

// AddonStatusResult holds addon status information.
type AddonStatusResult struct {
	Addons []AddonStatusInfo
}

// AddonStatusInfo holds status for a single addon.
type AddonStatusInfo struct {
	Name    string
	Enabled bool
	Props   []AddonStatusProp
}

// AddonStatusProp holds a single status property for an addon.
type AddonStatusProp struct {
	Name   string
	Value  string
	Okay   bool
}

// AddonExportConfig holds parameters for exporting addon state.
type AddonExportConfig struct {
	OutputDir  string
	Name       string // Empty means all enabled addons
	ShowOutput bool
}

// AddonImportConfig holds parameters for importing addon state.
type AddonImportConfig struct {
	InputDir   string
	Name       string // Empty means all
	ShowOutput bool
}
