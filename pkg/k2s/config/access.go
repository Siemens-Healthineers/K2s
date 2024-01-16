// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config

import (
	"k2s/config/load"
	"k2s/config/path"
	"k2s/providers/marshalling"
	"k2s/providers/os"
)

func NewAccess() *ConfigAccess {
	return NewConfigAccess(
		load.NewConfigLoader(
			os.NewFileReader(),
			marshalling.NewJsonUnmarshaller()),
		path.NewSetupConfigPathBuilder(os.NewDirProvider()))
}
