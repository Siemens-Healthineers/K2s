// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"errors"
	"fmt"
	"log/slog"
	"path/filepath"
	"strconv"
	"time"

	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"

	"github.com/spf13/cobra"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
)

type setupConfigProvider interface {
	ReadConfig(configDir string) (*setupinfo.Config, error)
}

type powershellExecutor interface {
	ExecutePsWithStructuredResult(psVersion powershell.PowerShellVersion, psCmd string, params ...string) (*common.CmdResult, error)
}

type setupConfigProviderImpl struct{}

type powershellExecutorImpl struct{}

func (s *setupConfigProviderImpl) ReadConfig(configDir string) (*setupinfo.Config, error) {
	return setupinfo.ReadConfig(configDir)
}

func (p *powershellExecutorImpl) ExecutePsWithStructuredResult(psVersion powershell.PowerShellVersion, psCmd string, params ...string) (*common.CmdResult, error) {
	return powershell.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psVersion, common.NewPtermWriter(), params...)
}

func newSetupConfigProvider() setupConfigProvider {
	return &setupConfigProviderImpl{}
}

func newPowershellExecutor() powershellExecutor {
	return &powershellExecutorImpl{}
}

const (
	containerdDirFlag     = "containerd"
	dockerDirFlag         = "docker"
	maxRetryFlag          = "max-retry"
	forceZapFlag          = "force-zap"
	forceZapFlagShorthand = "z"
	forceFlag             = "force"
	forceFlagShorthand    = "f"

	defaultMaxRetry = 1

	resetWinStorageCommandExample = `
  # Clean up containerd storage. This presents a user prompt before proceeding.
  k2s image reset-win-storage --containerd C:\containerd

  # Clean up docker storage. This presents a user prompt before proceeding.
  k2s image reset-win-storage --docker C:\docker

  # Clean up containerd storage without user prompts.
  k2s image reset-win-storage --containerd C:\containerd --force

  # Clean up both containerd and docker storages
  k2s image reset-win-storag --containerd C:\containerd --docker C:\docker

  # Clean up containerd storage with retries
  k2s image reset-win-storage --containerd C:\containerd --max-retry 5

  # Clean up containerd storage with additional zap.exe after all retries are exhausted.
  k2s image reset-win-storage --containerd C:\containerd --max-retry 5 --force-zap
`
)

var (
	defaultContainerdDir = determineDefaultDir("containerd")
	defaultDockerDir     = determineDefaultDir("docker")

	resetWinStorageCmd = &cobra.Command{
		Use:     "reset-win-storage",
		Short:   "Resets the containerd and docker image storage on windows nodes",
		RunE:    resetWinStorage,
		Example: resetWinStorageCommandExample,
	}

	getSetupConfigProvider func() setupConfigProvider
	getPowershellExecutor  func() powershellExecutor
)

func init() {
	resetWinStorageCmd.Flags().String(containerdDirFlag, defaultContainerdDir, "Containerd directory")
	resetWinStorageCmd.Flags().String(dockerDirFlag, defaultDockerDir, "Docker directory")
	resetWinStorageCmd.Flags().Int(maxRetryFlag, defaultMaxRetry, "Max retries for deleting the directories")
	resetWinStorageCmd.Flags().BoolP(forceZapFlag, "z", false, "Use zap.exe to forcefully remove the directory after all retries are exhausted.")
	resetWinStorageCmd.Flags().BoolP(forceFlag, forceFlagShorthand, false, "Trigger clean-up of windows container storage without user prompts")
	resetWinStorageCmd.Flags().SortFlags = false
	resetWinStorageCmd.Flags().PrintDefaults()

	getSetupConfigProvider = newSetupConfigProvider
	getPowershellExecutor = newPowershellExecutor
}

func resetWinStorage(cmd *cobra.Command, args []string) error {
	psCmd, params, err := buildResetPsCmd(cmd)
	if err != nil {
		return err
	}

	slog.Debug("PS command created", "command", psCmd, "params", params)

	start := time.Now()

	setupConfigProvider := getSetupConfigProvider()
	context := cmd.Context().Value(common.ContextKeyCmdContext).(*common.CmdContext)
	config, err := setupConfigProvider.ReadConfig(context.Config().Host.K2sConfigDir)
	if err != nil {
		if !(errors.Is(err, setupinfo.ErrSystemNotInstalled) || errors.Is(err, setupinfo.ErrSystemInCorruptedState)) {
			return err
		}
	}

	psVersion := common.GetDefaultPsVersion()
	if config != nil {
		psVersion = common.DeterminePsVersion(config)
	}

	powershellExecutor := getPowershellExecutor()
	cmdResult, err := powershellExecutor.ExecutePsWithStructuredResult(psVersion, psCmd, params...)

	if err != nil {
		return err
	}

	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}

	duration := time.Since(start)

	common.PrintCompletedMessage(duration, "image reset-win-storage")

	return nil
}

func buildResetPsCmd(cmd *cobra.Command) (psCmd string, params []string, err error) {
	psCmd = utils.FormatScriptFilePath(utils.InstallDir() + `\lib\scripts\k2s\image\ResetWinContainerStorage.ps1`)

	force, err := strconv.ParseBool(cmd.Flags().Lookup(forceFlag).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", forceFlag, err)
	}

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(common.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", common.OutputFlagName, err)
	}

	containerdDir, err := cmd.Flags().GetString(containerdDirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", containerdDirFlag, err)
	}

	if containerdDir == "" {
		slog.Info("Containerd directory set as empty, will use default dir", "default-dir", defaultContainerdDir)
		containerdDir = defaultContainerdDir
	}

	dockerDir, err := cmd.Flags().GetString(dockerDirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", dockerDirFlag, err)
	}

	if dockerDir == "" {
		slog.Info("Docker directory set as empty, will use default dir", "default-dir", defaultDockerDir)
		dockerDir = defaultDockerDir
	}

	maxRetries, err := cmd.Flags().GetInt(maxRetryFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", maxRetryFlag, err)
	}

	if maxRetries <= 0 {
		return "", nil, errors.New("illegal value for Max retries. Value of Max retries should be greater than or equal to 1")
	}

	useZap, err := strconv.ParseBool(cmd.Flags().Lookup(forceZapFlag).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", forceZapFlag, err)
	}

	params = append(params,
		" -Containerd "+utils.EscapeWithSingleQuotes(containerdDir),
		" -Docker "+utils.EscapeWithSingleQuotes(dockerDir),
		" -MaxRetries "+strconv.FormatUint(uint64(maxRetries), 10))

	if showOutput {
		params = append(params, " -ShowLogs")
	}

	if useZap {
		params = append(params, " -ForceZap")
	}

	if force {
		params = append(params, " -Force")
	}

	return
}

func determineDefaultDir(dirName string) string {
	return filepath.Join(host.SystemDrive(), dirName)
}
