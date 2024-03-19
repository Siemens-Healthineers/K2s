// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package json

import (
	j "encoding/json"
	"os"
)

func MarshalIndent(data any) ([]byte, error) {
	return j.MarshalIndent(data, "", "  ")
}

func FromFile[T any](filePath string) (v *T, err error) {
	binaries, err := os.ReadFile(filePath)
	if err != nil {
		return nil, err
	}

	err = j.Unmarshal(binaries, &v)
	if err != nil {
		return nil, err
	}

	return v, nil
}
