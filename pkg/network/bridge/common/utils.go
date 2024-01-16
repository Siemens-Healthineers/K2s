// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package common

import (
	"net"
	"strconv"

	"github.com/sirupsen/logrus"
)

// LogNetworkInterfaces logs the host's network interfaces in the default namespace.
func LogNetworkInterfaces() {
	interfaces, err := net.Interfaces()
	if err != nil {
		logrus.Errorf("Failed to query network interfaces, err:%v", err)
		return
	}

	for _, iface := range interfaces {
		addrs, _ := iface.Addrs()
		logrus.Debugf("[net] Network interface: %+v with IP addresses: %+v", iface, addrs)
	}
}

func GetAddressAsCidr(ip string, prefix uint8) string {

	return ip + string('/') + strconv.FormatUint(uint64(prefix), 10)

}
