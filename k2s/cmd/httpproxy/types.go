// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT
package main

type networkCIDRs []string

type proxyConfig struct {
	VerboseLogging *bool
	ListenAddress  *string
	ForwardProxy   *string
	AllowedCidrs   networkCIDRs
}
