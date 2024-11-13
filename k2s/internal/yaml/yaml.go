// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package yaml

import (
	"fmt"
	"os"

	y "gopkg.in/yaml.v3"
)

func FromFile[T any](path string) (v *T, err error) {
	binaries, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("could not read file '%s': %w", path, err)
	}

	err = y.Unmarshal(binaries, &v)
	if err != nil {
		return nil, fmt.Errorf("could not unmarshall file '%s' to yaml: %w", path, err)
	}
	return v, nil
}
