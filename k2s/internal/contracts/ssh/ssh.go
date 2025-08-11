// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import "time"

type ConnectionOptions struct {
	IpAddress         string
	Port              uint16
	RemoteUser        string
	SshPrivateKeyPath string
	Timeout           time.Duration
}

type CopyDirection bool

type CopyOptions struct {
	Source    string
	Target    string
	Direction CopyDirection
}

const (
	CopyToNode   CopyDirection = false
	CopyFromNode CopyDirection = true
)
