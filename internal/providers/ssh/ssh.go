// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"io"
	"time"
)

type ConnectionOptions struct {
	IpAddress         string
	Port              uint16
	RemoteUser        string
	SshPrivateKeyPath string
	Timeout           time.Duration
	StdOutWriter      io.Writer
}

type SSH struct {
	connectionOptions ConnectionOptions
}

func NewSSH(connectionOptions ConnectionOptions) *SSH {
	return &SSH{
		connectionOptions: connectionOptions,
	}
}
