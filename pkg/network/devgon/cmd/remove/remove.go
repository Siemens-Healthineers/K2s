// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package remove

import (
	"errors"
	"fmt"
	"io"
	"log/slog"
	"syscall"
	"unsafe"

	"github.com/gentlemanautomaton/windevice/deviceclass"
	"github.com/gentlemanautomaton/windevice/deviceid"
	"github.com/gentlemanautomaton/windevice/deviceregistry"
	"github.com/gentlemanautomaton/windevice/diflag"
	"github.com/gentlemanautomaton/windevice/difunc"
	"github.com/gentlemanautomaton/windevice/difuncremove"
	"github.com/gentlemanautomaton/windevice/hwprofile"
	"github.com/gentlemanautomaton/windevice/setupapi"
	"github.com/spf13/cobra"
)

const (
	hardwareInstanceIdFlag = "hardware-instance-id"
	removeExample          = `
	# Remove device with specific hardware instance ID
	devgon remove -i ROOT\NET\0001
  `
)

var (
	RemoveDeviceCmd = &cobra.Command{
		Use:     "remove",
		Short:   "Removes a device",
		Long:    ``,
		RunE:    execRemoveDeviceCmd,
		Example: removeExample,
	}
)

func init() {
	includeAddFlags(RemoveDeviceCmd)
}

func includeAddFlags(cmd *cobra.Command) {
	cmd.Flags().StringP(hardwareInstanceIdFlag, "i", "", `Hardware instance ID, e.g. 'ROOT\NET\0001'`)
	cmd.Flags().SortFlags = false
	cmd.Flags().PrintDefaults()
}

func execRemoveDeviceCmd(cmd *cobra.Command, args []string) error {
	hardwareInstanceId := cmd.Flags().Lookup(hardwareInstanceIdFlag).Value.String()

	if hardwareInstanceId == "" {
		return errors.New("hardware instance ID not specified")
	}

	devices, err := setupapi.GetClassDevsEx(nil, "", deviceclass.AllClasses, 0, "")
	if err != nil {
		return err
	}

	defer func() {
		if err = setupapi.DestroyDeviceInfoList(devices); err != nil {
			slog.Error("error while destroying device info list", "error", err)
		}
	}()

	slog.Info("Remove device started", "hardware instance ID", hardwareInstanceId)

	deviceInstanceId := deviceid.DeviceInstance(hardwareInstanceId)
	index := uint32(0)
	found := false

	for {
		device, err := setupapi.EnumDeviceInfo(devices, index)

		switch err {
		case nil:
		case io.EOF:
			slog.Info("Reached end of device list")
			if !found {
				slog.Warn("no device found", "hardware instance ID", hardwareInstanceId)
			}
			return nil
		default:
			return err
		}

		index++

		instanceId, err := setupapi.GetDeviceInstanceID(devices, device)
		if err != nil {
			slog.Error("error while retrieving data for device", "device", device, "error", err)
			continue
		}

		if instanceId != deviceInstanceId {
			continue
		}

		found = true

		if err := removeDevice(devices, device); err != nil {
			return err
		}

		break
	}
	return nil
}

func removeDevice(devices syscall.Handle, device setupapi.DevInfoData) error {
	friendlyName, err := setupapi.GetDeviceRegistryString(devices, device, deviceregistry.FriendlyName)
	if err != nil {
		return err
	}

	slog.Info("Found matching device", "device", friendlyName)

	diffParams := difuncremove.Params{
		Header: difunc.ClassInstallHeader{
			InstallFunction: difunc.Remove,
		},
		Scope:   hwprofile.Global,
		Profile: 0,
	}

	needReboot := false

	if err := setupapi.SetClassInstallParams(devices, &device, &diffParams.Header, uint32(unsafe.Sizeof(diffParams))); err != nil {
		return err
	}

	if err := setupapi.CallClassInstaller(difunc.Remove, devices, &device); err != nil {
		return err
	}

	slog.Info("Device removed, checking whether reboot is needed..", "device", friendlyName)

	deviceParams, err := setupapi.GetDeviceInstallParams(devices, &device)
	if err != nil {
		return fmt.Errorf("error while determining if reboot is needed: %w", err)
	}

	if deviceParams.Flags.Match(diflag.NeedReboot) || deviceParams.Flags.Match(diflag.NeedRestart) {
		needReboot = true
	}

	slog.Info("Reboot", "needed", needReboot)

	return nil
}
