// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k2s

import (
	"context"
	"encoding/json"
	"k2s/cmd/status/load"

	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

type k2sStatus struct {
	internal *load.Status
}

// wrapper around k2s.exe to retrieve and parse the cluster status
func (r *k2sCliRunner) GetStatus(ctx context.Context) *k2sStatus {
	output := r.Run(ctx, "status", "-o", "json")

	status := unmarshalStatus(output)

	return &k2sStatus{
		internal: status,
	}
}

func (status k2sStatus) GetEnabledAddons() []string {
	return status.internal.EnabledAddons
}

func (status k2sStatus) IsAddonEnabled(addonName string) bool {
	return lo.Contains(status.internal.EnabledAddons, addonName)
}

func (status k2sStatus) IsClusterRunning() bool {
	return status.internal.RunningState.IsRunning
}

func unmarshalStatus(statusJson string) *load.Status {
	var status load.Status

	err := json.Unmarshal([]byte(statusJson), &status)

	Expect(err).ToNot(HaveOccurred())

	return &status
}
