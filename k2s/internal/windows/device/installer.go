// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package device

import (
	"errors"
	"log/slog"
	"os"

	"github.com/gentlemanautomaton/windevice"
	"github.com/gentlemanautomaton/windevice/deviceid"
)

func Install(infPath string, hardwareId string) error {
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
