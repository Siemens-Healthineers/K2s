// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
	"unsafe"

	"github.com/sirupsen/logrus"
)

// Get the directory of the module
func GetModuleDirectory() string {
	exePath, err := os.Executable()
	if err != nil {
		logrus.Fatal("GetModuleDirectory: Error getting executable path, err:", err)
	}
	dir := filepath.Dir(exePath)
	logrus.Debug("Module directory where vfprules.dll is searched: ", dir)
	return dir
}

// VfpRoutes struct to hold the routes to be added
func VfpAddRule(name string, portid string, startip string, stopip string, priority string, gateway string) (uint32, error) {
	vfrulesDLL := syscall.NewLazyDLL(GetModuleDirectory() + "\\vfprules.dll")
	procVfpAddRule := vfrulesDLL.NewProc("VfpAddRule")
	ret, _, err := procVfpAddRule.Call(
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(name))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(portid))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(startip))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(stopip))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(priority))),
		uintptr(unsafe.Pointer(syscall.StringToUTF16Ptr(gateway))),
	)
	if ret != 0 {
		return uint32(ret), nil
	}
	return 0, err
}

// GetStartStopIp converts a subnet definition into start and stop IP addresses.
func GetStartStopIp(subnet string) (string, string, error) {
	// Parse the subnet definition
	ip, ipNet, err := net.ParseCIDR(subnet)
	if err != nil {
		return "", "", err
	}

	// Calculate the start IP address (the first IP in the subnet)
	startIp := ip.Mask(ipNet.Mask)

	// Calculate the stop IP address (the last IP in the subnet)
	stopIp := make(net.IP, len(startIp))
	for i := range startIp {
		stopIp[i] = startIp[i] | ^ipNet.Mask[i]
	}

	return startIp.String(), stopIp.String(), nil
}

// Function which adds the rules to the vfprules.dll using the VfpAddRule function
func AddVfpRulesWithVfpApi(portid string, port string, vfpRoutes *VfpRoutes, logDir string) error {
	logrus.Debug("[cni-net] AddVfpRulesWithVfpApi: ", portid, port, vfpRoutes, logDir)

	// go through rules and add them
	for _, vfpRoute := range vfpRoutes.Routes {
		debugLog := fmt.Sprintf("[cni-net] Name: %s, Subnet: %s, Gateway: %s, Priority: %s", vfpRoute.Name, vfpRoute.Subnet, vfpRoute.Gateway, vfpRoute.Priority)
		logrus.Info(debugLog)
		// get mac address of gateway
		mac, errmac := GetMacOfGateway(vfpRoute.Gateway)
		if errmac != nil {
			logrus.Info("AddVfpRules: Getting MAC not found error, will continue with the other rules, err:", errmac)
		} else {
			// build from subnet definition start and stop ip
			startip, stopip, err := GetStartStopIp(vfpRoute.Subnet)
			if err != nil {
				logrus.Info("AddVfpRules: Getting StartStopIp error, will continue with the other rules, err:", err)
				continue
			}

			// write the rules to be added using the vfprules.dll
			int32, error := VfpAddRule(vfpRoute.Name, portid, startip, stopip, vfpRoute.Priority, mac)
			if error != nil {
				logrus.Info("AddVfpRules: Adding rule error, will continue with the other rules, err:", error, " int32:", int32)
				continue
			}
		}
	}
	return nil
}
