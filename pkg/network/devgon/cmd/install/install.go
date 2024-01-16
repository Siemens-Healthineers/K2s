// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package install

import (
	"os"

	"github.com/gentlemanautomaton/windevice"
	"github.com/gentlemanautomaton/windevice/deviceid"
	"github.com/spf13/cobra"
	"k8s.io/klog/v2"
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
		Run:     installDevice,
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

func installDevice(cmd *cobra.Command, args []string) {
	infPath := cmd.Flags().Lookup(infPathFlag).Value.String()
	hardwareId := cmd.Flags().Lookup(hardwareIdFlag).Value.String()

	if infPath == "" {
		klog.Error("path to INF file not specified")
		return
	}

	if _, err := os.Stat(infPath); os.IsNotExist(err) {
		klog.Error(err)
		return
	}

	if hardwareId == "" {
		klog.Error("hardware ID not specified")
		return
	}

	deviceInstanceId, reboot, err := windevice.Install(deviceid.Hardware(hardwareId), infPath, "", 0)
	if err != nil {
		klog.Error(err)
		return
	}

	klog.V(2).Infof("Device '%s' installed, reboot required: '%v'", deviceInstanceId, reboot)
}
