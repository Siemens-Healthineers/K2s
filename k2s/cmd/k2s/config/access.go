// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"encoding/json"
	"os"

	"github.com/siemens-healthineers/k2s/cmd/k2s/config/path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/config/load"
)

func NewAccess() *ConfigAccess {
	return NewConfigAccess(
		load.NewConfigLoader(
			os.ReadFile,
			os.IsNotExist,
			json.Unmarshal),
		path.NewSetupConfigPathBuilder(os.UserHomeDir))
}
