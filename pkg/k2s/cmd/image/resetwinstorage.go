// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"base/system"
	"errors"
	"fmt"
	"k2s/utils"
	"k2s/utils/psexecutor"
	"path/filepath"
	"strconv"
	"time"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	"k2s/cmd/common"
	p "k2s/cmd/params"
)

const (
	containerdDirFlag = "containerd"
	dockerDirFlag     = "docker"
	maxRetryFlag      = "max-retry"
	forceZapFlag      = "force-zap"

	defaultMaxRetry = 1

	resetWinStorageCommandExample = `
  # Clean up containerd storage
  k2s image reset-win-storage --containerd C:\containerd

  # Clean up docker storage
  k2s image reset-win-storage --docker C:\docker

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
)

func init() {
	resetWinStorageCmd.Flags().String(containerdDirFlag, defaultContainerdDir, "Containerd directory")
	resetWinStorageCmd.Flags().String(dockerDirFlag, defaultDockerDir, "Docker directory")
	resetWinStorageCmd.Flags().Int(maxRetryFlag, defaultMaxRetry, "Max retries for deleting the directories")
	resetWinStorageCmd.Flags().BoolP(forceZapFlag, "f", false, "Use zap.exe to forcefully remove the directory after all retries are exhausted.")
	resetWinStorageCmd.Flags().SortFlags = false
	resetWinStorageCmd.Flags().PrintDefaults()
}

func resetWinStorage(cmd *cobra.Command, args []string) error {
	psCmd, params, err := buildResetPsCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(4).Infof("PS cmd: '%s', params: '%v'", psCmd, params)

	start := time.Now()

	cmdResult, err := psexecutor.ExecutePsWithStructuredResult[*common.CmdResult](psCmd, "CmdResult", psexecutor.ExecOptions{IgnoreNotInstalledErr: true}, params...)
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
	psCmd = utils.FormatScriptFilePath(utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ResetWinContainerStorage.ps1")

	showOutput, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", p.OutputFlagName, err)
	}

	containerdDir, err := cmd.Flags().GetString(containerdDirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", containerdDirFlag, err)
	}

	if containerdDir == "" {
		klog.V(3).Infof("Containerd Directory was specified as empty. Will use %s as containerd directory", defaultContainerdDir)
		containerdDir = defaultContainerdDir
	}

	dockerDir, err := cmd.Flags().GetString(dockerDirFlag)
	if err != nil {
		return "", nil, fmt.Errorf("unable to parse flag '%s': %w", dockerDirFlag, err)
	}

	if dockerDir == "" {
		klog.V(3).Infof("Docker Directory was specified as empty. Will use %s as docker directory", defaultContainerdDir)
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

	return
}

func determineDefaultDir(dirName string) string {
	return filepath.Join(system.SystemDrive(), dirName)
}
