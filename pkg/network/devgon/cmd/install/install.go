// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package install

import (
	"errors"
	"log/slog"
	"os"

	"github.com/gentlemanautomaton/windevice"
	"github.com/gentlemanautomaton/windevice/deviceid"
	"github.com/spf13/cobra"
)

const (
	infPathFlag    = "inf-path"
	hardwareIdFlag = "hardware-id"
)

var (
	installExample = `
  # Install device from INF file with specific hardware ID
  devgon install -p c:\windows\inf\netloop.inf -i *MSLOOP
`
	InstallDeviceCmd = &cobra.Command{
		Use:     "install",
		Short:   "Installs a device",
		Long:    ``,
		RunE:    installDevice,
		Example: installExample,
	}
)

func init() {
	includeAddFlags(InstallDeviceCmd)
}

func includeAddFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(infPathFlag, "p", "", `Path to the INF file, e.g. c:\windows\inf\netloop.inf`)
	cmd.Flags().StringP(hardwareIdFlag, "i", "", `Hardware ID, e.g. '*MSLOOP'`)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func installDevice(cmd *cobra.Command, args []string) error {
	infPath := cmd.Flags().Lookup(infPathFlag).Value.String()
	hardwareId := cmd.Flags().Lookup(hardwareIdFlag).Value.String()

	if infPath == "" {
		return errors.New("path to INF file not specified")
	}

	if _, err := os.Stat(infPath); os.IsNotExist(err) {
		return err
	}

	if hardwareId == "" {
		return errors.New("hardware ID not specified")
	}

	deviceInstanceId, reboot, err := windevice.Install(deviceid.Hardware(hardwareId), infPath, "", 0)
	if err != nil {
		return err
	}

	slog.Info("Device installed", "device", deviceInstanceId, "reboot required", reboot)

	return nil
}
