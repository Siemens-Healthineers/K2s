// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k2s

import (
	"context"
	"encoding/json"
	"k2s/cmd/status/load"

	. "github.com/onsi/gomega"
)

type K2sStatus struct {
	internal *load.LoadedStatus
}

// wrapper around k2s.exe to retrieve and parse the cluster status
func (r *K2sCliRunner) GetStatus(ctx context.Context) *K2sStatus {
	output := r.Run(ctx, "status", "-o", "json")

	status := unmarshalStatus[load.LoadedStatus](output)

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
