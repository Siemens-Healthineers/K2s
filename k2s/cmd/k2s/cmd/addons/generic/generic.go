// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package generic

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"sort"
	"time"

	"github.com/pterm/pterm"
	"github.com/samber/lo"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/powershell"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
)

func NewCommands(allAddons addons.Addons) (commands []*cobra.Command, err error) {
	commandMap := map[string]*cobra.Command{}

	for _, addon := range allAddons {
		if addon.Spec.Implementations[0].Commands == nil || len(*addon.Spec.Implementations[0].Commands) == 0 {
			return nil, fmt.Errorf("no cmd config found for addon '%s'", addon.Metadata.Name)
		}

		for cmdName, _ := range *addon.Spec.Implementations[0].Commands {
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
	slog.Debug("Creating sub-command for addon", "command", cmdName, "addon", addon.Metadata.Name)

	cmd := &cobra.Command{
		Use:   addon.Metadata.Name,
		Short: fmt.Sprintf("Runs '%s' for '%s' addon", cmdName, addon.Metadata.Name),
	}

	if len(addon.Spec.Implementations) > 1 {
		for _, implementation := range addon.Spec.Implementations {
			slog.Debug("Creating sub-command for addon implementation", "command", cmdName, "addon", addon.Metadata.Name, "implementation", implementation)
			implementationCmd, err := newImplementationCmd(addon, cmdName, implementation)
			if err != nil {
				return nil, err
			}
			cmd.AddCommand(implementationCmd)
		}
	} else {
		cmd.RunE = func(cmd *cobra.Command, args []string) error {
			return runCmd(cmd, addon, cmdName, addon.Spec.Implementations[0])
		}

		cmdConfig := (*addon.Spec.Implementations[0].Commands)[cmdName]
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
	}

	return cmd, nil
}

func newImplementationCmd(addon addons.Addon, cmdName string, implementation addons.Implementation) (*cobra.Command, error) {
	cmd := &cobra.Command{
		Use:   implementation.Name,
		Short: fmt.Sprintf("Runs '%s' for '%s' implementation of '%s' addon", cmdName, implementation.Name, addon.Metadata.Name),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runCmd(cmd, addon, cmdName, implementation)
		},
	}

	cmdConfig := (*implementation.Commands)[cmdName]
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

func runCmd(cmd *cobra.Command, addon addons.Addon, cmdName string, implementation addons.Implementation) error {
	if len(addon.Spec.Implementations) > 1 {
		slog.Info("Running addon command", "command", cmdName, "addon", addon.Metadata.Name, "implementation", implementation.Name)
		pterm.Printfln("🤖 Running '%s' for implementation '%s' of '%s' addon", cmdName, implementation.Name, addon.Metadata.Name)
	} else {
		slog.Info("Running addon command", "command", cmdName, "addon", addon.Metadata.Name)
		pterm.Printfln("🤖 Running '%s' for '%s' addon", cmdName, addon.Metadata.Name)
	}

	psCmd, params, err := buildPsCmd(cmd.Flags(), (*implementation.Commands)[cmdName], addon.Directory)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	cfg := cmd.Context().Value(common.ContextKeyConfig).(*config.Config)
	config, err := setupinfo.ReadConfig(cfg.Host.K2sConfigDir)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemInCorruptedState) {
			return common.CreateSystemInCorruptedStateCmdFailure()
		}
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
		return err
	}

	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", common.DeterminePsVersion(config), common.NewPsCommandOutputWriter(), params...)
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

	if flag.Name == common.OutputFlagName {
		add("-ShowLogs")
		return nil
	}

	scriptParam, found := lo.Find(cmdConfig.Script.ParameterMappings, func(mapping addons.ParameterMapping) bool {
		return mapping.CliFlagName == flag.Name
	})

	if !found {
		slog.Warn("CLI flag set, but missing PowerShell parameter mapping in `parameterMappings` of `addon.manifest.yaml`; not parameterized.", "flag", flag.Name, "value", flag.Value)
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
