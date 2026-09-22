// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package tempdir

import (
	"fmt"
	"os"

	"github.com/siemens-healthineers/k2s/internal/definitions"
)

func CreateTempDir() (string, error) {
	tempDir, err := os.MkdirTemp("", definitions.SetupNameK2s+"-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temporary directory: %w", err)
	}
	return tempDir, nil
}

func RemoveTempDir(tempDir string) error {
	err := os.RemoveAll(tempDir)
	if err != nil {
		return fmt.Errorf("failed to remove temporary directory: %w", err)
	}
	return nil
}
