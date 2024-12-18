// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node

import (
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
)

func Connect(connectionOptions ssh.ConnectionOptions) error {
	return ssh.ConnectInteractively(connectionOptions)
}
