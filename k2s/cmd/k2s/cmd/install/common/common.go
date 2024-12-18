// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package common

import (
	cc "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	ic "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/install/config"

	"github.com/spf13/cobra"
)

type Installer interface {
	Install(kind ic.Kind, cmd *cobra.Command, buildCmdFunc func(config *ic.InstallConfig) (cmd string, err error), cmdSession cc.CmdSession) error
}
