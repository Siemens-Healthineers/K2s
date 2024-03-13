// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package marshalling

import j "encoding/json"

type JsonUnmarshaller struct {
}

type JsonMarshaller struct {
}

func NewJsonUnmarshaller() JsonUnmarshaller {
	return JsonUnmarshaller{}
}

func NewJsonMarshaller() JsonMarshaller {
	return JsonMarshaller{}
}

func (JsonUnmarshaller) Unmarshal(data []byte, v any) error {
	return j.Unmarshal(data, v)
}

func (JsonMarshaller) MarshalIndent(data any) ([]byte, error) {
	return j.MarshalIndent(data, "", "  ")
}
