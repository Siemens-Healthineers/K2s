// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"github.com/siemens-healthineers/k2s/internal/providers/os"

	"github.com/siemens-healthineers/k2s/internal/providers/marshalling"

	"github.com/siemens-healthineers/k2s/cmd/k2s/config/path"

	"github.com/siemens-healthineers/k2s/cmd/k2s/config/load"
)

func NewAccess() *ConfigAccess {
	return NewConfigAccess(
		load.NewConfigLoader(
			os.NewFileReader(),
			marshalling.NewJsonUnmarshaller()),
		path.NewSetupConfigPathBuilder(os.NewDirProvider()))
}
