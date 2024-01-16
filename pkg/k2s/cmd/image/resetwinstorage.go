// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"base/system"
	"errors"
	"fmt"
	"path/filepath"
	"k2s/utils"
	"strconv"

	"github.com/spf13/cobra"
	"k8s.io/klog/v2"

	p "k2s/cmd/params"
)

var resetWinStorageCommandExample = `
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

const (
	containerdDirFlag = "containerd"
	dockerDirFlag     = "docker"
	maxRetryFlag      = "max-retry"
	forceZapFlag      = "force-zap"

	defaultMaxRetry = 1
	defaultForceZap = false

	scriptRelativePath = "\\smallsetup\\helpers\\ResetWinContainerStorage.ps1"
)

var (
	defaultContainerdDir string
	defaultDockerDir     string
)

var resetWinStorageCmd = &cobra.Command{
	Use:     "reset-win-storage",
	Short:   "Resets the containerd and docker image storage on windows nodes",
	RunE:    resetWinStorage,
	Example: resetWinStorageCommandExample,
}

func init() {
	resetWinStorageCmd.Flags().String(containerdDirFlag, determineDefaultContainerdDir(), "Containerd directory")
	resetWinStorageCmd.Flags().String(dockerDirFlag, determineDefaultDockerDir(), "Docker directory")
	resetWinStorageCmd.Flags().Int(maxRetryFlag, defaultMaxRetry, "Max retries for deleting the directories")
	resetWinStorageCmd.Flags().BoolP(forceZapFlag, "f", false, "Use zap.exe to forcefully remove the directory after all retries are exhausted.")
	resetWinStorageCmd.Flags().SortFlags = false
	resetWinStorageCmd.Flags().PrintDefaults()
}

func determineDefaultContainerdDir() string {
	defaultContainerdDir = filepath.Join(system.SystemDrive(), "containerd")

	return defaultContainerdDir
}

func determineDefaultDockerDir() string {
	defaultDockerDir = filepath.Join(system.SystemDrive(), "docker")

	return defaultDockerDir
}

func resetWinStorage(cmd *cobra.Command, args []string) error {
	builtCommand, err := buildResetWinStorageCmd(cmd)
	if err != nil {
		return err
	}

	klog.V(3).Infof("Reset win storage command: %s", builtCommand)

	_, err = utils.ExecutePowershellScript(builtCommand)
	if err != nil {
		return err
	}

	return nil
}

func buildResetWinStorageCmd(cmd *cobra.Command) (string, error) {
	resetCommand := utils.FormatScriptFilePath(utils.GetInstallationDirectory() + scriptRelativePath)

	outputFlag, err := strconv.ParseBool(cmd.Flags().Lookup(p.OutputFlagName).Value.String())
	if err != nil {
		return "", err
	}

	containerdDirectory, err := cmd.Flags().GetString(containerdDirFlag)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s due to error: %s", containerdDirFlag, err.Error())
	}
	if containerdDirectory == "" {
		klog.V(3).Infof("Containerd Directory was specified as empty. Will use %s as containerd directory", defaultContainerdDir)
		containerdDirectory = defaultContainerdDir
	}

	dockerDirectory, err := cmd.Flags().GetString(dockerDirFlag)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s due to error: %s", dockerDirFlag, err.Error())
	}
	if dockerDirectory == "" {
		klog.V(3).Infof("Docker Directory was specified as empty. Will use %s as docker directory", defaultContainerdDir)
		dockerDirectory = defaultDockerDir
	}

	maxRetries, err := cmd.Flags().GetInt(maxRetryFlag)
	if err != nil {
		return "", fmt.Errorf("unable to parse flag: %s due to error: %s", maxRetryFlag, err.Error())
	}
	if maxRetries <= 0 {
		return "", errors.New("illegal value for Max retries. Value of Max retries should be greater than or equal to 1")
	}

	zapFlag, err := strconv.ParseBool(cmd.Flags().Lookup(forceZapFlag).Value.String())
	if err != nil {
		return "", err
	}

	resetCommand += " -Containerd " + utils.EscapeWithSingleQuotes(containerdDirectory)
	resetCommand += " -Docker " + utils.EscapeWithSingleQuotes(dockerDirectory)
	resetCommand += " -MaxRetries " + strconv.FormatUint(uint64(maxRetries), 10)
	if outputFlag {
		resetCommand += " -ShowLogs"
	}
	if zapFlag {
		resetCommand += " -ForceZap"
	}

	return resetCommand, nil
}
