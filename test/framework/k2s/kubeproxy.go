// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package k2s

import (
	"context"
	"path/filepath"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
)

type KubeProxyRestarter struct {
	setupInfo    SetupInfo
	cliExecutor  CliExecutor
	K2sCliRunner K2sCliRunner
	nssmPath     string
}

func NewKubeProxyRestarter(setupInfo SetupInfo, cliExecutor CliExecutor, K2sCliRunner K2sCliRunner) *KubeProxyRestarter {
	return &KubeProxyRestarter{
		setupInfo:    setupInfo,
		cliExecutor:  cliExecutor,
		K2sCliRunner: K2sCliRunner,
		nssmPath:     filepath.Join(setupInfo.RootDir, "bin", "nssm.exe"),
	}
}

func (r *KubeProxyRestarter) Restart(ctx context.Context) {
	if r.setupInfo.SetupType.LinuxOnly {
		GinkgoWriter.Println("Linux-only setup, skipping kubeproxy restart")
	} else {
		r.restart(ctx)
	}
}

func (r *KubeProxyRestarter) restart(ctx context.Context) {
	GinkgoWriter.Println("Restarting kubeproxy to clean all caches..")

	if r.setupInfo.SetupType.Name == "MultiVMK8s" {
		r.K2sCliRunner.Run(ctx, "system", "ssh", "w", "--", "nssm", "restart", "kubeproxy")
	} else {
		r.cliExecutor.ExecOrFail(ctx, r.nssmPath, "restart", "kubeproxy")
	}

	GinkgoWriter.Println("kubeproxy restarted")
}
