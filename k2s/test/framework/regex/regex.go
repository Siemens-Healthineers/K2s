// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package regex

import "regexp"

const (
	IpAddressRegex = `((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}`
	VersionRegex   = `v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)`
)

var ansiEscapeRegex = regexp.MustCompile(`\x1b\[[0-9;]*m`)

func StripAnsi(s string) string {
	return ansiEscapeRegex.ReplaceAllString(s, "")
}
