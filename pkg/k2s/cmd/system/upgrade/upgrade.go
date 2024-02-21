// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package upgrade

import (
	"strconv"

	"github.com/pterm/pterm"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
	"k2s/utils"
	"k2s/utils/psexecutor"
)

var upgradeCommandShortDescription = "Upgrade your current cluster to this version"

var upgradeCommandLongDescription = `
Upgrades current K8s cluster to a newer version.
The steps how this is done:
1. Export of current workloads (global resources and all namespaced resources)
2. Keeps addons and their persistency in order re-enable after upgrade
3. Uninstall existing cluster
4. Install a new cluster based on the new version
5. Import previous exported workloads
6. Enables addons and restores persistency
7. Check if all workloads are running
8. Final check on cluster availability
`

var upgradeCommandExample = `
  # Upgrades the cluster to the new version, call this from the folder where the new version was deployed:
  k2s upgrade

  # Upgrades the cluster to the new version, skips takeover of resources
  k2s upgrade -s

  # Upgrades the cluster to the new version, delete downloaded files and get all logs on the console
  k2s upgrade -d -o
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
	cmd.Flags().BoolP(deleteFiles, "d", false, "Delete downloaded content")
	cmd.Flags().StringP(configFileFlagName, "c", "", "Path to config file to load. This configuration overwrites other CLI parameters")
	cmd.Flags().StringP(proxy, "p", defaultProxy, "HTTP Proxy")
	cmd.Flags().BoolP(skipImages, "i", false, "Skip takeover of container images from old cluster to new cluster")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func upgradeCluster(cmd *cobra.Command, args []string) error {
	pterm.Println("🤖 Analyze current cluster and check prerequisites ...")
	upgradeCommand := createUpgradeCommand(cmd)
	klog.V(3).Infof("Upgrade Command : %s", upgradeCommand)

	duration, err := psexecutor.ExecutePowershellScript(upgradeCommand)
	if err != nil {
		return err
	}

	common.PrintCompletedMessage(duration, "Upgrade")

	return nil
}

func createUpgradeCommand(cmd *cobra.Command) string {
	upgradeCommand := utils.GetInstallationDirectory() + "\\smallsetup\\upgrade\\" + "Start-ClusterUpgrade.ps1"
	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		klog.V(3).Infof("Param: %s: %s\n", f.Name, f.Value)
	})
	out, _ := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if out {
		upgradeCommand += " -ShowLogs"
	}
	skip, _ := strconv.ParseBool(cmd.Flags().Lookup(skipK8sResources).Value.String())
	if skip {
		upgradeCommand += " -SkipResources "
	}
	keep, _ := strconv.ParseBool(cmd.Flags().Lookup(deleteFiles).Value.String())
	if keep {
		upgradeCommand += " -DeleteFiles "
	}
	config := cmd.Flags().Lookup(configFileFlagName).Value.String()
	if len(config) > 0 {
		upgradeCommand += " -Config " + config
	}
	proxy := cmd.Flags().Lookup(proxy).Value.String()
	if len(proxy) > 0 {
		upgradeCommand += " -Proxy " + proxy
	}
	skipImages, _ := strconv.ParseBool(cmd.Flags().Lookup(skipImages).Value.String())
	if skipImages {
		upgradeCommand += " -SkipImages "
	}
	return upgradeCommand
}
