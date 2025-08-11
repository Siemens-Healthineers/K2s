// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package k2s

import (
	"context"
	"path/filepath"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
)

type KubeProxyRestarter struct {
	runtimeConfig config.K2sRuntimeConfig
	cliExecutor   CliExecutor
	K2sCliRunner  K2sCliRunner
	nssmPath      string
}

func NewKubeProxyRestarter(rootDir string, setupInfo config.K2sRuntimeConfig, cliExecutor CliExecutor, K2sCliRunner K2sCliRunner) *KubeProxyRestarter {
	return &KubeProxyRestarter{
		runtimeConfig: setupInfo,
		cliExecutor:   cliExecutor,
		K2sCliRunner:  K2sCliRunner,
		nssmPath:      filepath.Join(rootDir, "bin", "nssm.exe"),
	}
}

func (r *KubeProxyRestarter) Restart(ctx context.Context) {
	if r.runtimeConfig.InstallConfig().LinuxOnly() {
		GinkgoWriter.Println("Linux-only setup, skipping kubeproxy restart")
	} else {
		r.restart(ctx)
	}
}

func (r *KubeProxyRestarter) restart(ctx context.Context) {
	GinkgoWriter.Println("Restarting kubeproxy to clean all caches..")

	r.cliExecutor.ExecOrFail(ctx, r.nssmPath, "restart", "kubeproxy")

	GinkgoWriter.Println("kubeproxy restarted")
}
