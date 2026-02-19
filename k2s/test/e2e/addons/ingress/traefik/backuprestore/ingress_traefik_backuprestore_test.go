// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package backuprestore

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	k2s        *dsl.K2s
	testFailed = false
	backupDir  string
)

func TestIngressTraefikBackupRestore(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ingress traefik Addon Backup/Restore Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "setup-required", "invasive", "ingress", "traefik", "backup-restore", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	k2s = dsl.NewK2s(suite)

	backupDir = filepath.Join(os.TempDir(), "k2s-test-backup-ingress-traefik")
})

var _ = AfterSuite(func(ctx context.Context) {
	if suite == nil {
		return
	}

	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "traefik", "-o")

	cleanupBackupDir()

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

func cleanupBackupDir() {
	os.RemoveAll(backupDir)
}

func backupZipPath(suffix string) string {
	return filepath.Join(backupDir, fmt.Sprintf("ingress_traefik_backup_%s.zip", suffix))
}

var _ = Describe("'ingress traefik' addon backup/restore", Ordered, func() {

	const (
		ingressName     = "traefik-cluster-local"
		namespace       = "ingress-traefik"
		annotationKey   = "k2s-test/marker"
		annotationValue = "backup-restore-sentinel"
	)

	var zipPath string

	BeforeAll(func() {
		zipPath = backupZipPath("basic")
		cleanupBackupDir()
		os.MkdirAll(backupDir, os.ModePerm)
	})

	AfterAll(func(ctx context.Context) {
		suite.K2sCli().Exec(ctx, "addons", "disable", "ingress", "traefik", "-o")
		k2s.VerifyAddonIsDisabled("ingress", "traefik")
	})

	// --- error tests while addon is disabled (cheap, no lifecycle cost) ---

	It("fails backup when addon is disabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "backup", "ingress", "traefik")

		Expect(output).To(ContainSubstring("not enabled"))
	})

	It("fails restore with a non-existent backup file", func(ctx context.Context) {
		fakePath := filepath.Join(backupDir, "does-not-exist.zip")

		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "ingress", "traefik", "-f", fakePath)

		Expect(output).To(ContainSubstring("not found"))
	})

	// --- single enable → annotate ingress → backup → disable → restore cycle ---

	It("enables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "enable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")
	})

	It("annotates the Ingress resource with a custom marker", func(ctx context.Context) {
		suite.Kubectl().MustExec(ctx, "annotate", "ingress", ingressName, "-n", namespace,
			fmt.Sprintf("%s=%s", annotationKey, annotationValue))

		output := suite.Kubectl().MustExec(ctx, "get", "ingress", ingressName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", annotationKey))
		Expect(output).To(Equal(annotationValue))
	})

	It("creates a backup", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "backup", "ingress", "traefik", "-f", zipPath, "-o")

		Expect(zipPath).To(BeAnExistingFile())
	})

	It("fails restore while addon is still enabled", func(ctx context.Context) {
		output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "addons", "restore", "ingress", "traefik", "-f", zipPath)

		Expect(output).To(ContainSubstring("disable"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "disable", "ingress", "traefik", "-o")

		k2s.VerifyAddonIsDisabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeRemoved(ctx, "app.kubernetes.io/name", "traefik", "ingress-traefik")
	})

	It("restores from backup and the annotation is present", func(ctx context.Context) {
		suite.K2sCli().MustExec(ctx, "addons", "restore", "ingress", "traefik", "-f", zipPath, "-o")

		k2s.VerifyAddonIsEnabled("ingress", "traefik")

		suite.Cluster().ExpectDeploymentToBeAvailable("traefik", "ingress-traefik")

		output := suite.Kubectl().MustExec(ctx, "get", "ingress", ingressName, "-n", namespace,
			"-o", fmt.Sprintf("jsonpath={.metadata.annotations['%s']}", annotationKey))
		Expect(output).To(Equal(annotationValue))
	})
})
