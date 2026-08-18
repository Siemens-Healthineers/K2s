// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package output

type Writer interface {
	WriteStdOut(message string)
	WriteStdErr(message string)
	Flush()
}
