// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package json

import j "encoding/json"

func MarshalIndent(data any) ([]byte, error) {
	return j.MarshalIndent(data, "", "  ")
}
