// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image/registry"

	"github.com/spf13/cobra"
)

var ImageCmd = &cobra.Command{
	Use:   "image",
	Short: "Manage images",
}

func init() {
	ImageCmd.AddCommand(listCmd)
	ImageCmd.AddCommand(cleanCmd)
	ImageCmd.AddCommand(removeCmd)
	ImageCmd.AddCommand(exportCmd)
	ImageCmd.AddCommand(importCmd)
	ImageCmd.AddCommand(registry.Cmd)
	ImageCmd.AddCommand(resetWinStorageCmd)
	ImageCmd.AddCommand(buildCmd)
	ImageCmd.AddCommand(pullCmd)
}
