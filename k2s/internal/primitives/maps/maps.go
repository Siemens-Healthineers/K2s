// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package maps

import (
	"fmt"
)

func GetValue[T any](key string, dictionary map[string]any) (value T, err error) {
	anyValue, ok := dictionary[key]
	if !ok {
		return value, fmt.Errorf("map does not contain key '%s'", key)
	}

	value, ok = anyValue.(T)
	if !ok {
		return value, fmt.Errorf("cannot convert map value to '%T'", value)
	}

	return value, nil
}
