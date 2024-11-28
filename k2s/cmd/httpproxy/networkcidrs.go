// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"net"
	"strings"
)

func newNetworkCidrs() networkCIDRs {
	return make([]string, 0)
}

func (i *networkCIDRs) String() string {
	return strings.Join([]string(*i), ",")

}

func (i *networkCIDRs) Set(value string) error {
	err := i.isValidNetworkCidr(value)
	if err != nil {
		return err
	}
	*i = append(*i, value)
	return nil
}

func (i *networkCIDRs) ToIPNet() ([]*net.IPNet, error) {
	ipNets := make([]*net.IPNet, 0)
	for _, cidrString := range *i {
		_, ipNet, err := net.ParseCIDR(cidrString)
		if err != nil {
			return nil, err
		}
		ipNets = append(ipNets, ipNet)
	}
	return ipNets, nil
}

func (i *networkCIDRs) isValidNetworkCidr(value string) error {
	_, _, err := net.ParseCIDR(value)
	if err != nil {
		return err
	}
	return nil
}
