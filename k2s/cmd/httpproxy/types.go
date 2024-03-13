// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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
