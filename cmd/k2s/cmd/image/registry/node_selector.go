// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package registry

import (
	"fmt"
	"os"
	"strings"

	contracts "github.com/siemens-healthineers/k2s/internal/contracts/config"
)

func validateNodeSelector(nodeSelector string, runtimeConfig *contracts.K2sRuntimeConfig) error {
	if nodeSelector == "" {
		return nil
	}

	if runtimeConfig.InstallConfig().LinuxOnly() {
		if strings.Contains(nodeSelector, ",") {
			return fmt.Errorf("multi-node selection '%s' is not supported on a Linux-only installation; only the local Linux host is available", nodeSelector)
		}

		lower := strings.ToLower(nodeSelector)
		if strings.Contains(lower, "win") {
			return fmt.Errorf("node '%s' is a Windows worker node; Linux-only installations do not contain Windows worker nodes", nodeSelector)
		}

		var cpHostname string
		if runtimeConfig.ControlPlaneConfig() != nil {
			cpHostname = strings.ToLower(runtimeConfig.ControlPlaneConfig().Hostname())
		}
		localHost, _ := os.Hostname()
		localHost = strings.ToLower(localHost)

		if lower != "linux" && (cpHostname == "" || lower != cpHostname) && (localHost == "" || lower != localHost) {
			hostname := ""
			if runtimeConfig.ControlPlaneConfig() != nil {
				hostname = runtimeConfig.ControlPlaneConfig().Hostname()
			}
			if hostname == "" {
				hostname = localHost
			}
			return fmt.Errorf("node '%s' is not part of this cluster; Linux-only installation only targets the local host node ('%s')", nodeSelector, hostname)
		}
	}

	return nil
}
