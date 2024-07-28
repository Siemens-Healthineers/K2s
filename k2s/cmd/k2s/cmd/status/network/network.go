// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package network

import (
	"log/slog"

	c "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/config"
	factory "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/factory"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/resultobserver"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/terminalprinter"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/workloaddeployer"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/spf13/cobra"
)

const (
	outputFlagName   = "output"
	nodeNamesFlag    = "nodes"
	jsonOption       = "json"
	defaultNamespace = "k2s"

	networkStatusCommandExample = `
  # Networking status of the cluster
  k2s status network
`
)

var nodes []string

var NetworkStatusCmd = &cobra.Command{
	Use:     "network",
	Short:   "Provides overview of K2s cluster networking in the installed machine",
	RunE:    PrintNetworkStatus,
	Example: networkStatusCommandExample,
}

func init() {
	NetworkStatusCmd.Flags().StringP(outputFlagName, "o", "", "Output format modifier. Currently supported: 'json' for output as JSON structure")
	NetworkStatusCmd.Flags().StringSliceVarP(&nodes, nodeNamesFlag, "n", []string{}, "List of nodes to deploy networking probes, if empty then deployed on all available nodes")
	NetworkStatusCmd.Flags().SortFlags = false
	NetworkStatusCmd.Flags().PrintDefaults()
}

func PrintNetworkStatus(cmd *cobra.Command, args []string) error {
	outputOption, err := cmd.Flags().GetString(outputFlagName)
	if err != nil {
		return err
	}

	logger := terminalprinter.NewPrinterContext(outputOption)

	logger.LogInfo("Starting cluster network check")
	logger.StartSpinnerMsg("Deploying network probes...")

	cfg, err := getClusterConfig()
	if err != nil {
		return err
	}

	f, err := factory.NewClusterFactory(cfg)
	if err != nil {
		slog.Error("Failed to create factory: %v", "error", err)
		return err
	}

	// Deploy
	deployer := f.CreateWorkloadDeployer()
	deployParam := workloaddeployer.DeployParam{
		Namespace: defaultNamespace,
		NodeNames: nodes,
	}
	err = deployer.Deploy(deployParam)
	if err != nil {
		slog.Error("Failed to deploy network probes: %v", "error", err)
		return err
	}

	logger.StopSpinner()
	logger.LogInfo("Network probes deployed, proceeding with network checks")
	logger.StartSpinnerMsg("Performing network checks...")

	nodeGroups, err := deployer.GetNodeGroups(defaultNamespace)
	if err != nil {
		slog.Error("Failed to get node groups %v", "error", err)
		return err
	}

	// Start rule creation
	handlers := networkchecker.CreateNetworkCheckHandlers(*f.Client, nodeGroups)

	nf := &factory.ClusterNetworkFactory{}
	observers := nf.CreateResultObservers(outputOption)

	for _, handler := range handlers {
		for _, observer := range observers {
			handler.AddObserver(observer)
		}
	}

	// Create network check chain
	networkCheckChain := nf.CreateNetworkCheckChain(handlers...)
	_, err = networkCheckChain.CheckConnectivity()
	if err != nil {
		return err
	}

	logger.StopSpinner()

	// Print summary
	for _, observer := range observers {
		logger, ok := observer.(resultobserver.ResultObserver)
		if ok {
			logger.DumpSummary()
		}
	}

	// cleanup
	logger.StartSpinnerMsg("Cleaning up network probes...")

	deployer.Remove(deployParam)

	logger.StopSpinner()

	return nil
}

func getClusterConfig() (*c.Config, error) {
	config, err := config.LoadConfig(utils.InstallDir())
	if err != nil {
		return nil, err
	}

	cfg := &c.Config{
		KubeConfig: config.Host.KubeConfigDir + "\\config",
		Namespace:  defaultNamespace,
	}
	return cfg, nil
}
