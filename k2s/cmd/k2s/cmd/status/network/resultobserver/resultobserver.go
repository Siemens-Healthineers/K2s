// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package resultobserver

import (
	"strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/networkchecker"
)

type ResultObserver interface {
	DumpSummary()
}

const defaultErrStatus = "---"

func NewObserver(format string) ResultObserver {
	switch format {
	case "json":
		return NewJSONLogObserver()
	default:
		return NewPrettyLogObserver()
	}
}

// common utilities
func resolveErrorMessage(status string, errorMessage string) string {
	if status != networkchecker.StatusOK {
		return extractCurlErrorMessage(errorMessage)
	}

	return defaultErrStatus

}

func extractCurlErrorMessage(errorMessage string) string {
	const substring = "curl:"
	// Extract the substring after "curl:"
	index := strings.Index(errorMessage, substring)
	if index != -1 {
		curlErrorMessage := strings.TrimSpace(errorMessage[index:])
		return curlErrorMessage
	}

	return errorMessage
}
