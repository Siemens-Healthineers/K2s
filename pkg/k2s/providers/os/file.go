// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package os

import o "os"

type FileReader struct {
}

func NewFileReader() FileReader {
	return FileReader{}
}

func (ofr FileReader) Read(filename string) ([]byte, error) {
	return o.ReadFile(filename)
}

func (ofr FileReader) IsFileNotExist(err error) bool {
	return o.IsNotExist(err)
}
