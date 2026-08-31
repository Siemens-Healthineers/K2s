// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package registry

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/terminal"

	"github.com/spf13/cobra"
)

var (
	listExample = `
	# List configured image registries in K2s 
	k2s image registry ls

	# List registries on a specific node
	k2s image registry ls --node worker-1

	# List registries on multiple specific nodes
	k2s image registry ls --nodes worker-1,worker-2
`

	listCmd = &cobra.Command{
		Use:     "ls",
		Short:   "List configured registries",
		RunE:    listRegistries,
		Example: listExample,
	}
)

func init() {
	listCmd.Flags().String(nodeFlag, "", "Node name to target (e.g. worker-1)")
	listCmd.Flags().String(nodesFlag, "", "Comma-separated node names to target (e.g. worker-1,worker-2)")
	listCmd.Flags().SortFlags = false
	listCmd.Flags().PrintDefaults()
}

func listRegistries(cmd *cobra.Command, args []string) error {
	nodeSelection, err := cmd.Flags().GetString(nodeFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodeFlag, err)
	}

	nodesSelection, err := cmd.Flags().GetString(nodesFlag)
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", nodesFlag, err)
	}

	nodesParam := nodesSelection
	if nodesParam == "" {
		nodesParam = nodeSelection
	}

	// If node(s) specified, call PowerShell script
	if nodesParam != "" {
		return listRegistriesOnNodes(cmd, nodesParam)
	}

	// Default: list global registries
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	runtimeConfig, err := config.ReadRuntimeConfig(context.Config().Host().K2sSetupConfigDir())
	if err != nil {
		if errors.Is(err, cconfig.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, cconfig.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	registries := runtimeConfig.ClusterConfig().Registries()

	terminalPrinter := terminal.NewTerminalPrinter()

	if len(registries) == 0 {
		terminalPrinter.PrintInfoln("No registries configured!")
		return nil
	}

	terminalPrinter.PrintHeader("Configured registries:")
	for _, v := range registries {
		terminalPrinter.Printfln(" - %s", v)
	}

	return nil
}

func listRegistriesOnNodes(cmd *cobra.Command, nodesParam string) error {
	psCmd := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "registry", "List-Registries.ps1"))

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	params := []string{
		" -Nodes " + utils.EscapeWithSingleQuotes(nodesParam),
	}

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	return nil
}
