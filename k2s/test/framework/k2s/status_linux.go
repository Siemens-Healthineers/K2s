// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
// SPDX-License-Identifier: MIT

//go:build linux

package k2s

import (
	"context"

	"github.com/siemens-healthineers/k2s/test/framework/os"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
)

// StatusChecker verifies native Linux K2s availability through the API server.
type StatusChecker struct {
	newCliFunc func(cliPath string) *os.CliExecutor
	setupInfo  *SetupInfo
}

func NewStatusChecker(newCliFunc func(cliPath string) *os.CliExecutor, setupInfo *SetupInfo) *StatusChecker {
	return &StatusChecker{
		newCliFunc: newCliFunc,
		setupInfo:  setupInfo,
	}
}

// IsK2sRunning checks the native control plane using the kubeconfig supplied
// by the Linux acceptance-test runner.
func (sc *StatusChecker) IsK2sRunning(ctx context.Context) bool {
	GinkgoWriter.Println("Checking native Linux K2s API server status..")
	sc.setupInfo.ReloadRuntimeConfig()

	_, exitCode := sc.newCliFunc("kubectl").NoStdOut().Exec(ctx, "cluster-info", "--request-timeout=10s")
	isRunning := exitCode == 0
	GinkgoWriter.Println("K2s system running:", isRunning)
	return isRunning
}
