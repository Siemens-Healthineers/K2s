// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package arrays

func Insert[T any](array []T, item T, index int) []T {
	return append(array[:index], append([]T{item}, array[index:]...)...)
}
