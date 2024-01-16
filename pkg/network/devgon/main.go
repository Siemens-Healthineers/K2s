// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"devgon/cmd"

	"k8s.io/klog/v2"
)

func main() {
	defer klog.Flush()

	err := cmd.Execute()

	if err != nil {
		klog.Error(err)
	}
}
