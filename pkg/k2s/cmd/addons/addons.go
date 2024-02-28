// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package addons

import (
	"errors"
	"fmt"
	"k2s/addons"
	"k2s/cmd/addons/cmd/addonimport"
	"k2s/cmd/addons/cmd/export"
	"k2s/cmd/addons/cmd/list"
	"k2s/cmd/addons/cmd/status"
	"k2s/cmd/common"
	"k2s/setupinfo"
	"k2s/utils/logging"
	"k2s/utils/psexecutor"
	"os"
	"slices"
	"sort"
	"time"

	"k2s/cmd/params"
	"k2s/utils"
	"path/filepath"

	"github.com/spf13/cobra"

	"github.com/pterm/pterm"
	"github.com/samber/lo"
	"github.com/spf13/pflag"
	"k8s.io/klog/v2"
)

func NewCmd() *cobra.Command {
	var cmd = &cobra.Command{
		Use:   "addons",
		Short: "Manage addons",
		Long:  "Addons add optional functionality to a K8s cluster",
	}

	cmd.AddCommand(addonimport.NewCommand())
	cmd.AddCommand(export.NewCommand())

	if !slices.Contains(os.Args, cmd.Use) {
		return cmd
	}

	addons := addons.AllAddons()

	logAddons(addons)

	// TODO: create generic commands for all addons
	cmd.AddCommand(list.NewCommand())
	cmd.AddCommand(status.NewCommand(addons))

	commands, err := createGenericCommands(addons)
	if err != nil {
		klog.Fatal(err)
	}

	cmd.AddCommand(commands...)

	return cmd
}

func createGenericCommands(allAddons addons.Addons) (commands []*cobra.Command, err error) {
	commandMap := map[string]*cobra.Command{}

	for _, addon := range allAddons {
		if addon.Spec.Commands == nil || len(*addon.Spec.Commands) == 0 {
			return nil, fmt.Errorf("no cmd config found for addon '%s'", addon.Metadata.Name)
		}

		for cmdName, _ := range *addon.Spec.Commands {
			if _, ok := commandMap[cmdName]; !ok {
				klog.V(4).Infof("cmd '%s' not existing, creating it", cmdName)

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
	klog.V(4).Infof("creating sub-cmd '%s' for addon '%s'", cmdName, addon.Metadata.Name)

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
	klog.V(4).Infof("Running '%s' for '%s' addon..", cmdName, addon.Metadata.Name)
	pterm.Printfln("🤖 Running '%s' for '%s' addon", cmdName, addon.Metadata.Name)

	psCmd, params, err := buildPsCmd(cmd.Flags(), (*addon.Spec.Commands)[cmdName], addon.Directory)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{}, params...)
	if err != nil {
		if errors.Is(err, setupinfo.ErrSystemNotInstalled) {
			return common.CreateSystemNotInstalledCmdFailure()
		}
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
			klog.V(4).Infof("previous error detected, skipping flag '%s'..", f.Name)
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
		klog.V(4).Infof("flag '%s' set with value '%v', but not considered for parameterization", flag.Name, flag.Value)
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

// workaround to log the addons at least to file, because the verbosity level is not set yet from the CLI flags,
// because loading addons currently happens in init() calls, not on command execution (where the CLI flags get finally parsed)
func logAddons(allAddons addons.Addons) {
	logging.DisableCliOutput()

	addonInfos := lo.Map(allAddons, func(a addons.Addon, _ int) struct{ Name, Directory string } {
		return struct{ Name, Directory string }{Name: a.Metadata.Name, Directory: a.Directory}
	})

	klog.InfoS("addons loaded", "count", len(addonInfos), "addons", addonInfos)

	logging.EnableCliOutput()
}
