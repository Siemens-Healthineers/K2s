// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package importcmd

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/powershell"

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

  # Import without the images belonging to an omitted functionality
  k2s addons import -f C:\tmp\addons.oci.tar --omit omitCertMgr

  # Scope an omit option to one addon or one implementation
  k2s addons import -f C:\tmp\addons.oci.tar --omit security:omitKeycloak --omit ingress/nginx:omitCertMgr
`

const (
	fileLabel     = "file"
	defaultFile   = ""
	nodeFlagName  = "node"
	omitFlagName  = "omit"
	omitFlagUsage = "Skip the images of an omitted addon functionality, e.g. 'omitCertMgr' or 'ingress/nginx:omitCertMgr'. Repeatable. An image is only skipped when no imported addon still requires it."
)

func NewCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "import ADDON",
		Short: "Import an addon from an OCI artifact",
		Long: `Import one or more addons from an OCI-compliant artifact.

Use --omit to leave out the container images that belong to an addon functionality you
do not intend to enable. The OCI artifact is never modified, so the same artifact can be
imported again later without the omit option to add the missing images.

An image is only skipped when no addon selected for this import still requires it. If, for
example, 'ingress nginx' is imported with --omit omitCertMgr while 'security' is imported
too, the cert-manager images are still imported because 'security' requires them.`,
		Example: importCommandExample,
		RunE:    runImport,
	}

	cmd.Flags().StringP(fileLabel, "f", defaultFile, "OCI artifact tar file of exported addon")
	cmd.Flags().String(nodeFlagName, "", "Target node name for addon image import (e.g. worker-1); defaults to control-plane and local Windows host when omitted")
	cmd.Flags().StringArray(omitFlagName, []string{}, omitFlagUsage)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd
}

func runImport(cmd *cobra.Command, args []string) error {
	cmdSession := common.StartCmdSession(cmd.CommandPath())
	allAddons, err := addons.LoadAddons(utils.InstallDir())
	if err != nil {
		return err
	}

	ac.LogAddons(allAddons)

	if cmd.Flags().Changed(nodeFlagName) {
		nodeOption, nodeErr := cmd.Flags().GetString(nodeFlagName)
		if nodeErr != nil {
			return nodeErr
		}
		if strings.TrimSpace(nodeOption) == "" {
			return fmt.Errorf("the --node flag was provided but is empty - specify a valid node name (run 'kubectl get nodes' to list available nodes)")
		}
	}

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
	params = appendNodesParam(params, nodeSelector)

	omitOptions, err := parseOmitOptions(cmd)
	if err != nil {
		return "", nil, err
	}
	params = appendOmitParam(params, omitOptions)

	return
}

// parseOmitOptions reads the repeatable --omit flag and returns the trimmed, non-empty tokens.
// A token is either a bare flag name ('omitCertMgr') or an addon-scoped one
// ('security:omitKeycloak', 'ingress/nginx:omitCertMgr'). Validation against the addons
// actually contained in the artifact happens in Import.ps1, because the artifact may carry
// addons that are not installed yet and therefore unknown to the CLI.
func parseOmitOptions(cmd *cobra.Command) ([]string, error) {
	values, err := cmd.Flags().GetStringArray(omitFlagName)
	if err != nil {
		return nil, fmt.Errorf("unable to parse flag: %s", omitFlagName)
	}

	options := make([]string, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		options = append(options, trimmed)
	}

	return options, nil
}

// appendOmitParam appends the -Omit parameter only when at least one option was provided,
// preserving the existing behavior (import everything) when omitted.
func appendOmitParam(params []string, options []string) []string {
	if len(options) == 0 {
		return params
	}

	quoted := make([]string, 0, len(options))
	for _, option := range options {
		quoted = append(quoted, utils.EscapeWithSingleQuotes(option))
	}

	return append(params, " -Omit "+strings.Join(quoted, ","))
}

// parseNodeSelector reads the --node flag and returns the trimmed node name (empty when not set).
// An explicitly-provided blank/whitespace value is rejected earlier in runImport with an error,
// so here we simply trim; an empty result yields the default targets (control-plane + Windows host).
func parseNodeSelector(cmd *cobra.Command) (string, error) {
	nodeOption, err := cmd.Flags().GetString(nodeFlagName)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(nodeOption), nil
}

// appendNodesParam appends the -Nodes parameter to the PS call only when a node selector is provided,
// preserving the existing default behavior (control-plane + local Windows host) when omitted.
func appendNodesParam(params []string, nodes string) []string {
	if strings.TrimSpace(nodes) == "" {
		return params
	}

	return append(params, " -Nodes "+utils.EscapeWithSingleQuotes(nodes))
}
