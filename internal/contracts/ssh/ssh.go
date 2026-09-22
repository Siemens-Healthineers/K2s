// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

// TODO: back to ssh package?

type CopyDirection bool

type CopyOptions struct {
	Source    string
	Target    string
	Direction CopyDirection
}

const (
	CopyToNode   CopyDirection = false
	CopyFromNode CopyDirection = true
)
