// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package decode

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"fmt"
	"io"
	"strings"
)

const (
	separator     = "#"
	marker        = "#pm#"
	segmentsCount = 4
)

func IsEncodedMessage(message string) bool {
	return strings.HasPrefix(message, marker)
}

func DecodeMessage(message string, targetType string) ([]byte, error) {
	payload, err := extractPayload(message, targetType)
	if err != nil {
		return nil, err
	}

	decodedBytes, err := decodeBase64(payload)
	if err != nil {
		return nil, err
	}

	uncompressedBytes, err := uncompress(decodedBytes)
	if err != nil {
		return nil, err
	}

	return uncompressedBytes, nil
}

func extractPayload(message string, targetType string) ([]byte, error) {
	segments := strings.Split(message, separator)

	if len(segments) != segmentsCount {
		return nil, fmt.Errorf("message malformed: fount '%d' segments instead of '%d'", len(segments), segmentsCount)
	}

	actualType := segments[2]

	if actualType != targetType {
		return nil, fmt.Errorf("message type mismatch: Expected '%s', but got '%s'", targetType, actualType)
	}

	return []byte(segments[3]), nil
}

func decodeBase64(data []byte) ([]byte, error) {
	decodedBytes := make([]byte, base64.StdEncoding.DecodedLen(len(data)))

	decodedLen, err := base64.StdEncoding.Decode(decodedBytes, data)
	if err != nil {
		return nil, err
	}

	return decodedBytes[:decodedLen], nil
}

func uncompress(data []byte) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}

	return io.ReadAll(reader)
}
