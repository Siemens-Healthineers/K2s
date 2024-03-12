// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"k2s/addons"
	"log/slog"

	"github.com/samber/lo"
)

type addonInfos struct{ allAddons addons.Addons }

func LogAddons(allAddons addons.Addons) {
	slog.Debug("addons loaded", "count", len(allAddons), "addons", addonInfos{allAddons})
}

// LogValue is a slog.LogValuer implementation to defer the construction of a parameter until the verbosity level is determined
func (ai addonInfos) LogValue() slog.Value {
	infos := lo.Map(ai.allAddons, func(a addons.Addon, _ int) struct{ Name, Directory string } {
		return struct{ Name, Directory string }{Name: a.Metadata.Name, Directory: a.Directory}
	})

	return slog.AnyValue(infos)
}
