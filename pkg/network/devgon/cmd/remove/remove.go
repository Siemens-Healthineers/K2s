// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package remove

import (
	"io"
	"log"
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
	"k8s.io/klog/v2"
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
		Run:     execRemoveDeviceCmd,
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

func execRemoveDeviceCmd(cmd *cobra.Command, args []string) {
	hardwareInstanceId := cmd.Flags().Lookup(hardwareInstanceIdFlag).Value.String()

	if hardwareInstanceId == "" {
		klog.Error("hardware instance ID not specified")
		return
	}

	devices, err := setupapi.GetClassDevsEx(nil, "", deviceclass.AllClasses, 0, "")
	if err != nil {
		klog.Error(err)
		return
	}

	defer func() {
		err = setupapi.DestroyDeviceInfoList(devices)
		if err != nil {
			klog.Error(err)
		}
	}()

	klog.V(2).Infof("Remove device started with hardware instance ID '%s'", hardwareInstanceId)

	deviceInstanceId := deviceid.DeviceInstance(hardwareInstanceId)
	index := uint32(0)
	found := false

	for {
		device, err := setupapi.EnumDeviceInfo(devices, index)

		switch err {
		case nil:
		case io.EOF:
			klog.V(2).Info("Reached end of device list")
			if !found {
				klog.Warningf("no device found for hardware instance ID '%s'", hardwareInstanceId)
			}
			return
		default:
			klog.Error(err)
			return
		}

		index++

		instanceId, err := setupapi.GetDeviceInstanceID(devices, device)
		if err != nil {
			klog.Errorf("Error while retrieving data for device '%v': %v", device, err)
			continue
		}

		if instanceId != deviceInstanceId {
			continue
		}

		found = true

		removeDevice(devices, device)

		break
	}
}

func removeDevice(devices syscall.Handle, device setupapi.DevInfoData) {
	friendlyName, err := setupapi.GetDeviceRegistryString(devices, device, deviceregistry.FriendlyName)
	if err != nil {
		log.Fatal(err)
	}

	klog.V(2).Infof("Found matching device '%s'", friendlyName)

	diffParams := difuncremove.Params{
		Header: difunc.ClassInstallHeader{
			InstallFunction: difunc.Remove,
		},
		Scope:   hwprofile.Global,
		Profile: 0,
	}

	needReboot := false

	if err := setupapi.SetClassInstallParams(devices, &device, &diffParams.Header, uint32(unsafe.Sizeof(diffParams))); err != nil {
		klog.Error(err)
		return
	}

	if err := setupapi.CallClassInstaller(difunc.Remove, devices, &device); err != nil {
		klog.Error(err)
		return
	}

	klog.V(2).Infof("Device '%s' removed, checking whether reboot is needed..", friendlyName)

	deviceParams, err := setupapi.GetDeviceInstallParams(devices, &device)
	if err != nil {
		klog.Errorf("Error while determining if reboot is needed: %v", err)
		return
	}

	if deviceParams.Flags.Match(diflag.NeedReboot) || deviceParams.Flags.Match(diflag.NeedRestart) {
		needReboot = true
	}

	klog.V(2).Infof("Need reboot: '%v'", needReboot)
}
