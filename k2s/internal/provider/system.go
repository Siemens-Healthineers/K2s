// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package provider

// SystemProvider abstracts system-level operations (dump, upgrade, packaging, etc.).
// On Windows: delegates to PowerShell scripts.
// On Linux: uses native commands (kubectl, qemu-img, etc.).
type SystemProvider interface {
	// Dump collects diagnostic information from the cluster.
	Dump(config SystemDumpConfig) error

	// Upgrade upgrades the K2s cluster from a package.
	Upgrade(config SystemUpgradeConfig) error

	// Package creates an offline installation package.
	Package(config SystemPackageConfig) error

	// Reset resets the K2s system to a clean state.
	Reset(config SystemResetConfig) error

	// ResetNetwork resets the cluster networking.
	ResetNetwork(config SystemResetNetworkConfig) error

	// Compact compacts VM disk images to reclaim space.
	Compact(config SystemCompactConfig) error

	// Backup creates a backup of the cluster state.
	Backup(config SystemBackupConfig) error

	// Restore restores the cluster from a backup.
	Restore(config SystemRestoreConfig) error

	// CertificateRenew renews the Kubernetes certificates.
	CertificateRenew(config SystemCertRenewConfig) error
}

// SystemDumpConfig holds parameters for the dump operation.
type SystemDumpConfig struct {
<<<<<<< HEAD
	OutputDir    string
	SkipOpenDump bool
	ShowOutput   bool
=======
	OutputDir  string
	ShowOutput bool
>>>>>>> main
}

// SystemUpgradeConfig holds parameters for the upgrade operation.
type SystemUpgradeConfig struct {
	PackagePath        string
<<<<<<< HEAD
	ConfigFile         string
	Proxy              string
	BackupDir          string
	AdditionalHooksDir string
	SkipImages         bool
	SkipResources      bool
	ForceOnline        bool
	Force              bool
=======
	AdditionalHooksDir string
	SkipImages         bool
	ForceOnline        bool
>>>>>>> main
	ShowOutput         bool
	DeletePackage      bool
}

// SystemPackageConfig holds parameters for the package operation.
type SystemPackageConfig struct {
	OutputDir          string
	ForDeltaPackage    bool
	BasePackagePath    string
	TargetPackagePath  string
	ShowOutput         bool
}

// SystemResetConfig holds parameters for the reset operation.
type SystemResetConfig struct {
	ShowOutput bool
}

// SystemResetNetworkConfig holds parameters for network reset.
type SystemResetNetworkConfig struct {
	AdditionalHooksDir string
<<<<<<< HEAD
	Force              bool
=======
>>>>>>> main
	ShowOutput         bool
}

// SystemCompactConfig holds parameters for the compact operation.
type SystemCompactConfig struct {
<<<<<<< HEAD
	NoRestart  bool
	Yes        bool
=======
>>>>>>> main
	ShowOutput bool
}

// SystemBackupConfig holds parameters for the backup operation.
type SystemBackupConfig struct {
<<<<<<< HEAD
	BackupFile         string
	AdditionalHooksDir string
	SkipImages         bool
	SkipPVs            bool
	ShowOutput         bool
=======
	BackupDir  string
	ShowOutput bool
>>>>>>> main
}

// SystemRestoreConfig holds parameters for the restore operation.
type SystemRestoreConfig struct {
<<<<<<< HEAD
	BackupFile         string
	AdditionalHooksDir string
	ErrorOnFailure     bool
	ShowOutput         bool
=======
	BackupDir  string
	ShowOutput bool
>>>>>>> main
}

// SystemCertRenewConfig holds parameters for certificate renewal.
type SystemCertRenewConfig struct {
<<<<<<< HEAD
	Force      bool
=======
>>>>>>> main
	ShowOutput bool
}
