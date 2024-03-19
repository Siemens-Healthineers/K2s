// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"errors"
	"fmt"
	"log/slog"
	"os"
	"slices"
	"sort"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/cmd/addonimport"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/cmd/export"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/cmd/list"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/cmd/status"

	"github.com/siemens-healthineers/k2s/cmd/k2s/addons"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils/psexecutor"

	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/params"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/spf13/cobra"

	"github.com/pterm/pterm"
	"github.com/samber/lo"
	"github.com/spf13/pflag"
)

func NewCmd() (*cobra.Command, error) {
	var cmd = &cobra.Command{
		Use:   "addons",
		Short: "Manage addons",
		Long:  "Addons add optional functionality to a K8s cluster",
	}

	cmd.AddCommand(addonimport.NewCommand())
	cmd.AddCommand(export.NewCommand())

	if !slices.Contains(os.Args, cmd.Use) {
		return cmd, nil
	}

	addons, err := addons.LoadAddons()
	if err != nil {
		return nil, err
	}

	// TODO: create generic commands for all addons
	cmd.AddCommand(list.NewCommand(addons))
	cmd.AddCommand(status.NewCommand(addons))

	commands, err := createGenericCommands(addons)
	if err != nil {
		return nil, err
	}

	cmd.AddCommand(commands...)

	return cmd, nil
}

func createGenericCommands(allAddons addons.Addons) (commands []*cobra.Command, err error) {
	commandMap := map[string]*cobra.Command{}

	for _, addon := range allAddons {
		if addon.Spec.Commands == nil || len(*addon.Spec.Commands) == 0 {
			return nil, fmt.Errorf("no cmd config found for addon '%s'", addon.Metadata.Name)
		}

		for cmdName, _ := range *addon.Spec.Commands {
			if _, ok := commandMap[cmdName]; !ok {
				slog.Debug("Command not existing, creating it", "command", cmdName)

				cmd := &cobra.Command{
					Use:   cmdName,
					Short: fmt.Sprintf("Runs '%s' for the specific addon", cmdName),
				}
				commandMap[cmdName] = cmd
			}

			subCmd, err := newAddonCmd(addon, cmdName)
			if err != nil {
				return nil, err
			}

			commandMap[cmdName].AddCommand(subCmd)
		}
	}

	keys := lo.Keys(commandMap)
	sort.Strings(keys)

	lo.ForEach(keys, func(item string, _ int) {
		commands = append(commands, commandMap[item])
	})

	return
}

func newAddonCmd(addon addons.Addon, cmdName string) (*cobra.Command, error) {
	slog.Debug("Creating sub-command for addond", "command", cmdName, "addon", addon.Metadata.Name)

	cmdConfig := (*addon.Spec.Commands)[cmdName]
	cmd := &cobra.Command{
		Use:   addon.Metadata.Name,
		Short: fmt.Sprintf("Runs '%s' for '%s' addon", cmdName, addon.Metadata.Name),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCmd(cmd, addon, cmdName)
		},
	}

	if cmdConfig.Cli != nil {
		cmd.Example = cmdConfig.Cli.Examples.String()

		for _, flag := range cmdConfig.Cli.Flags {
			if err := addFlag(flag, cmd.Flags()); err != nil {
				return nil, err
			}
		}
	}

	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()

	return cmd, nil
}

func addFlag(flag addons.CliFlag, flagSet *pflag.FlagSet) error {
	flagDescription, err := flag.FullDescription()
	if err != nil {
		return err
	}

	switch defaultValue := flag.Default.(type) {
	case string:
		if flag.Shorthand != nil {
			flagSet.StringP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.String(flag.Name, defaultValue, flagDescription)
		}
	case bool:
		if flag.Shorthand != nil {
			flagSet.BoolP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Bool(flag.Name, defaultValue, flagDescription)
		}
	case int:
		if flag.Shorthand != nil {
			flagSet.IntP(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Int(flag.Name, defaultValue, flagDescription)
		}
	case float64:
		if flag.Shorthand != nil {
			flagSet.Float64P(flag.Name, *flag.Shorthand, defaultValue, flagDescription)
		} else {
			flagSet.Float64(flag.Name, defaultValue, flagDescription)
		}
	default:
		return fmt.Errorf("unsupported flag value: %v", defaultValue)
	}

	return nil
}

func runCmd(cmd *cobra.Command, addon addons.Addon, cmdName string) error {
	slog.Info("Running addon command", "command", cmdName, "addon", addon.Metadata.Name)
	pterm.Printfln("🤖 Running '%s' for '%s' addon", cmdName, addon.Metadata.Name)

	psCmd, params, err := buildPsCmd(cmd.Flags(), (*addon.Spec.Commands)[cmdName], addon.Directory)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	configDir := cmd.Context().Value(common.ContextKeyConfigDir).(string)
	config, err := setupinfo.LoadConfig(configDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{PowerShellVersion: powershell.DeterminePsVersion(config)}, params...)
	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)
	common.PrintCompletedMessage(duration, fmt.Sprintf("addons %s %s", cmdName, addon.Metadata.Name))

	return nil
}

func buildPsCmd(flags *pflag.FlagSet, cmdConfig addons.AddonCmd, addonDir string) (cmd string, params []string, err error) {
	cmd = utils.FormatScriptFilePath(filepath.Join(addonDir, cmdConfig.Script.SubPath))
	addParam := func(param string) { params = append(params, param) }

	flags.Visit(func(f *pflag.Flag) {
		if err != nil {
			slog.Debug("Previous error detected, skipping flag", "flag", f.Name)
			return
		}

		err = convertToPsParam(f, cmdConfig, addParam)
	})

	return cmd, params, err
}

func convertToPsParam(flag *pflag.Flag, cmdConfig addons.AddonCmd, add func(string)) error {
	if flag == nil {
		return errors.New("flag must not be nil")
	}

	if flag.Name == params.OutputFlagName {
		add("-ShowLogs")
		return nil
	}

	scriptParam, found := lo.Find(cmdConfig.Script.ParameterMappings, func(mapping addons.ParameterMapping) bool {
		return mapping.CliFlagName == flag.Name
	})

	if !found {
		slog.Debug("flag set, but not considered for parameterization", "flag", flag.Name, "value", flag.Value)
		return nil
	}

	if flag.Value.Type() == "bool" {
		add(fmt.Sprintf("-%s", scriptParam.ScriptParameterName))
		return nil
	}

	if cmdConfig.Cli == nil {
		return fmt.Errorf("CLI config must not be nil for flag '%s'", flag.Name)
	}

	flagConfig, found := lo.Find(cmdConfig.Cli.Flags, func(f addons.CliFlag) bool {
		return f.Name == flag.Name
	})

	if !found {
		return fmt.Errorf("flag config not found for flag '%s'", flag.Name)
	}

	if err := flagConfig.Constraints.Validate(flag.Value); err != nil {
		return fmt.Errorf("validation error for flag '%s': %v", flag.Name, err)
	}

	add(fmt.Sprintf("-%s %v", scriptParam.ScriptParameterName, flag.Value))
	return nil
}
