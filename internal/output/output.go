// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package output

type StreamWriter interface {
	WriteStdOut(message string)
	WriteStdErr(message string)
	Flush()
}
