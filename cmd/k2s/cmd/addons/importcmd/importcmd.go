// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package importcmd

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"

	"github.com/siemens-healthineers/k2s/internal/providers/powershell"

	ac "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/common"
	cconfig "github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/internal/core/config"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"
)

var importCommandExample = `
  # Import multiple addons from an exported OCI artifact
  k2s addons import registry ingress nginx -f C:\tmp\addons.oci.tar

  # Import all addons from an exported OCI artifact
  k2s addons import -f C:\tmp\addons.oci.tar

  # Import addons targeting a specific node
  k2s addons import registry -f C:\tmp\addons.oci.tar --node worker-1

  # Import addons targeting multiple nodes
  k2s addons import registry -f C:\tmp\addons.oci.tar --nodes worker-1,worker-2
`

const (
	fileLabel     = "file"
	defaultFile   = ""
	nodeFlagName  = "node"
	nodesFlagName = "nodes"
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "import ADDON",
		Short:   "Import an addon from an OCI artifact",
		Example: importCommandExample,
		RunE:    runImport,
	}

	cmd.Flags().StringP(fileLabel, "f", defaultFile, "OCI artifact tar file of exported addon")
	cmd.Flags().String(nodeFlagName, "", "Target node name for addon image import (e.g. worker-1); defaults to control-plane and local Windows host when omitted")
	cmd.Flags().String(nodesFlagName, "", "Target node names (comma-separated) for addon image import (e.g. worker-1,worker-2)")
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runImport(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())

	effectiveFlag := ""
	if cmd.Flags().Changed(nodesFlagName) {
		effectiveFlag = nodesFlagName
	} else if cmd.Flags().Changed(nodeFlagName) {
		effectiveFlag = nodeFlagName
	}

	if effectiveFlag != "" {
		nodeOption, nodeErr := cmd.Flags().GetString(effectiveFlag)
		if nodeErr != nil {
			return nodeErr
		}
		if common.IsNodeSelectorEmpty(nodeOption) {
			return fmt.Errorf("the --%s flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)", effectiveFlag)
		}
	}

	allAddons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	psCmd, params, err := buildPsCmd(cmd, args...)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

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

	if runtimeConfig.InstallConfig().LinuxOnly() {
		return common.CreateFuncUnavailableForLinuxOnlyCmdFailure()
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	cmdSession.Finish()

	return nil
}

func buildPsCmd(cmd *cobra.Command, addons ...string) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "addons", "Import.ps1"))

	if len(addons) > 0 {
		names := ""
		for _, addon := range addons {
			names += utils.EscapeWithSingleQuotes(addon) + ","
		}
		names = names[:len(names)-1]

		params = append(params, " -Names "+names)
	}

	imagePath, err := cmd.Flags().GetString(fileLabel)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag: %s", fileLabel)
	}
	if imagePath == "" {
		return "", nil, errors.New("no path to OCI artifact provided")
	}

	imagePath, err = filepath.Abs(imagePath)
	if err != nil {
		return "", nil, fmt.Errorf("unable to resolve absolute path for artifact file: %w", err)
	}

	params = append(params, " -ArtifactFile "+utils.EscapeWithSingleQuotes(imagePath))

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, err
	}

	if outputFlag {
		params = append(params, " -ShowLogs")
	}

	nodeSelector, err := parseNodeSelector(cmd)
	if err != nil {
		return "", nil, err
	}
	params = common.AppendNodesParam(params, nodeSelector)

	return
}

// parseNodeSelector reads the --nodes (or fallback --node) flag and returns the trimmed node name(s) (empty when not set).
// When both flags are specified, --nodes takes precedence over --node.
// An explicitly-provided blank/whitespace/comma-only value is rejected earlier in runImport with an error,
// so here we simply trim; an empty result yields the default targets (control-plane + Windows host).
func parseNodeSelector(cmd *cobra.Command) (string, error) {
	return common.ParseNodeSelector(cmd, nodeFlagName, nodesFlagName)
}
