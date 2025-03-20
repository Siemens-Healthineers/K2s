// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package reflection

import (
	"reflect"
	"runtime"
	"strings"
)

func GetFunctionName(function interface{}) string {
	fullPath := runtime.FuncForPC(reflect.ValueOf(function).Pointer()).Name()
	pathParts := strings.Split(fullPath, ".")
	name := pathParts[len(pathParts)-1]
	nameParts := strings.Split(name, "-")

	return nameParts[0]
}
