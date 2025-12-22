// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package k2s

import (
	"context"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/ginkgo/v2"
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/test/framework/os"
)

type KubeProxyRestarter struct {
	runtimeConfig config.K2sRuntimeConfig
	nssmCli       *os.CliExecutor
}

func NewKubeProxyRestarter(setupInfo config.K2sRuntimeConfig, nssmCli *os.CliExecutor) *KubeProxyRestarter {
	return &KubeProxyRestarter{
		runtimeConfig: setupInfo,
		nssmCli:       nssmCli,
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

	r.nssmCli.MustExec(ctx, "restart", "kubeproxy")

	GinkgoWriter.Println("kubeproxy restarted")
}
