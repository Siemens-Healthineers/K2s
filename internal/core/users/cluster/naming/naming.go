// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package naming

func DetermineK8sContext(userName, clusterName string) string {
	return userName + "@" + clusterName
}
