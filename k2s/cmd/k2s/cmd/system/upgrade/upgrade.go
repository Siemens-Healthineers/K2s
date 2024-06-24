// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"errors"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

var upgradeCommandShortDescription = "Upgrades the installed K2s cluster to this version"

var upgradeCommandLongDescription = `
Upgrades the installed K2s cluster to this version.

⚠  This command must be called within the folder containing the new K2s version, e.g. '<new-version-dir>\k2s.exe system upgrade'

The following tasks will be executed:
1. Export of current workloads (global resources and all namespaced resources)
2. Keeping addons and their persistency to be re-enabled after cluster upgrade
3. Uninstall existing cluster
4. Install a new cluster based on this version
5. Import previously exported workloads
6. Enable addons and restore persistency
7. Check if all workloads are running
8. Finally check K2s cluster availability
`

var upgradeCommandExample = `
  # Upgrades the cluster to this version
  k2s system upgrade

  # Upgrades the cluster to this version, skips takeover of existing cluster resources
  k2s system upgrade -s

  # Upgrades the cluster to this version, deleting downloaded files after upgrade
  k2s system upgrade -d
`

const (
	configFileFlagName = "config"
	skipK8sResources   = "skip-resources"
	deleteFiles        = "delete-files"
	proxy              = "proxy"
	defaultProxy       = ""
	skipImages         = "skip-images"
)

var UpgradeCmd = &cobra.Command{
	Use:     "upgrade",
	Short:   upgradeCommandShortDescription,
	Long:    upgradeCommandLongDescription,
	RunE:    upgradeCluster,
	Example: upgradeCommandExample,
}

func init() {
	AddInitFlags(UpgradeCmd)
}

func AddInitFlags(cmd *cobra.Command) {
	cmd.Flags().BoolP(skipK8sResources, "s", false, "Skip takeover of K8s resources from old cluster to new cluster")
	cmd.Flags().BoolP(deleteFiles, "d", false, "Delete downloaded files")
	cmd.Flags().StringP(configFileFlagName, "c", "", "Path to config file to load. This configuration overwrites other CLI parameters")
	cmd.Flags().StringP(proxy, "p", defaultProxy, "HTTP Proxy")
	cmd.Flags().BoolP(skipImages, "i", false, "Skip takeover of container images from old cluster to new cluster")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func upgradeCluster(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Analyze current cluster and check prerequisites ...")

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	if config.SetupName == setupinfo.SetupNameMultiVMK8s {
		return common.CreateFunctionalityNotAvailableCmdFailure(config.SetupName)
	}

	psCmd := createUpgradeCommand(cmd)

	slog.Debug("PS command created", "command", psCmd)

	outputWriter, err := common.NewOutputWriter()
	if err != nil {
		return err
	}

	start := time.Now()

	err = powershell.ExecutePs(psCmd, common.DeterminePsVersion(config), outputWriter)
	if err != nil {
		return err
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, "Upgrade")

	return nil
}

func createUpgradeCommand(cmd *cobra.Command) string {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "system", "upgrade", "Start-ClusterUpgrade.ps1"))
	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		slog.Debug("Param", "name", f.Name, "value", f.Value)
	})
	out, _ := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if out {
		psCmd += " -ShowLogs"
	}
	skip, _ := strconv.ParseBool(cmd.Flags().Lookup(skipK8sResources).Value.String())
	if skip {
		psCmd += " -SkipResources "
	}
	keep, _ := strconv.ParseBool(cmd.Flags().Lookup(deleteFiles).Value.String())
	if keep {
		psCmd += " -DeleteFiles "
	}
	config := cmd.Flags().Lookup(configFileFlagName).Value.String()
	if len(config) > 0 {
		psCmd += " -Config " + config
	}
	proxy := cmd.Flags().Lookup(proxy).Value.String()
	if len(proxy) > 0 {
		psCmd += " -Proxy " + proxy
	}
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImages).Value.String())
	if skipImages {
		psCmd += " -SkipImages "
	}
	return psCmd
}
