// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package json

import (
	j "encoding/json"
	"fmt"
	"io/fs"
	"os"
)

func MarshalIndent(data any) ([]byte, error) {
	return j.MarshalIndent(data, "", "  ")
}

func FromFile[T any](filePath string) (v *T, err error) {
	binaries, err := os.ReadFile(filePath)
	if err != nil {
		return nil, fmt.Errorf("error occurred while reading file '%s': %w", filePath, err)
	}

	err = j.Unmarshal(binaries, &v)
	if err != nil {
		return nil, fmt.Errorf("error occurred while unmarshalling file '%s': %w", filePath, err)
	}

	return v, nil
}

func ToFile[T any](filePath string, v *T) (err error) {
	binaries, err := j.Marshal(v)
	if err != nil {
		return fmt.Errorf("error occurred while marshalling file '%s': %w", filePath, err)
	}

	return os.WriteFile(filePath, binaries, fs.ModePerm)
}
