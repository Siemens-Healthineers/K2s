// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package k2s

import (
	"context"
	"encoding/json"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

type K2sStatus struct {
	internal *status.PrintStatus
}

// wrapper around k2s.exe to retrieve and parse the cluster status
func (r *K2sCliRunner) GetStatus(ctx context.Context) *K2sStatus {
	output := r.RunOrFail(ctx, "status", "-o", "json")

	status := unmarshalStatus[status.PrintStatus](output)

	return &K2sStatus{
		internal: status,
	}
}

func (status K2sStatus) IsClusterRunning() bool {
	return status.internal.RunningState.IsRunning
}

func unmarshalStatus[T any](statusJson string) *T {
	var status T

	err := json.Unmarshal([]byte(statusJson), &status)

	Expect(err).ToNot(HaveOccurred())

	return &status
}
