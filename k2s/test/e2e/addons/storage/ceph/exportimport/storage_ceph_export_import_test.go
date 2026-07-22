// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package cephexportimport

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/e2e/addons/exportimport"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const exportImportTestTimeout = time.Minute * 30

var (
	suite                 *framework.K2sTestSuite
	k2s                   *dsl.K2s
	exportPath            string
	exportedOciFile       string
	controlPlaneIpAddress string
	addon                 *addons.Addon
	impl                  *addons.Implementation
	testFailed            = false
)

func TestStorageCephExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage ceph Addon Export/Import Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "storage-ceph", "export-import", "air-gapped", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "storage-ceph-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	addon = exportimport.GetAddonByName(allAddons, "storage")
	Expect(addon).NotTo(BeNil(), "storage addon should exist")

	impl = exportimport.GetImplementation(addon, "ceph")
	Expect(impl).NotTo(BeNil(), "ceph implementation should exist")

	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if suite.ShouldCleanup(testFailed) {
		exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
	}
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("storage ceph addon export and import", Ordered, func() {
	Describe("export storage ceph addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports storage ceph addon to versioned OCI tar file", func(ctx context.Context) {
			exportedOciFile = exportimport.ExportAddon(ctx, suite, "storage", "ceph", exportPath)
			info, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported OCI tar file should exist at %s", exportedOciFile)
			Expect(info.Size()).To(BeNumerically(">", 0))
		})

		It("contains storage ceph addon folder with correct OCI structure", func(ctx context.Context) {
			extractedArtifactsDir := exportimport.ExtractOciTar(ctx, suite, exportedOciFile, exportPath)
			expectedDirName := exportimport.GetExpectedDirName("storage", "ceph")
			exportimport.VerifyExportedOciStructure(extractedArtifactsDir, expectedDirName)
		})

		It("exports all addon resources", func(ctx context.Context) {
			exportimport.VerifyExportedImages(suite, exportPath, impl)
			exportimport.VerifyExportedPackages(exportPath, impl)
		})
	})

	Describe("clean up storage ceph resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("has no debian packages available before import", func(ctx context.Context) {
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import storage ceph addon", func() {
		var restoreProxyEnvironment func()

		BeforeAll(func(ctx context.Context) {
			restoreProxyEnvironment = exportimport.PrepareAirGappedAddonImport(ctx, suite, controlPlaneIpAddress)
			exportimport.ImportAddon(ctx, suite, exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			suite.K2sCli().Exec(ctx, "addons", "disable", "storage", "ceph", "-f", "-o")
			if restoreProxyEnvironment != nil {
				restoreProxyEnvironment()
			}
			exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
		})

		It("has debian packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedDebPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("has images available after import", func(ctx context.Context) {
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})

		It("has linux and windows curl packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedLinuxCurlPackages(ctx, suite, impl, controlPlaneIpAddress)
			exportimport.VerifyImportedWindowsCurlPackages(suite, impl)
		})

		It("has expected addon files after import", func(ctx context.Context) {
			cephImplDir := filepath.Join(suite.RootDir(), "addons", "storage", "ceph")
			expectedFiles := []string{
				"Enable.ps1",
				"Disable.ps1",
				"Get-Status.ps1",
				"Backup.ps1",
				"Restore.ps1",
				"EnableForRestore.ps1",
				"README.md",
				"config/ceph-config.json",
				"config/ceph-config.json.license",
				"manifests/operator.yaml",
				"manifests/csi-rbac.yaml",
				"manifests/crds/ceph-crd.yaml",
			}
			exportimport.VerifyImportedAddonFiles(cephImplDir, expectedFiles)
		})

		It("addon can be enabled while air-gapped", func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "enable", "storage", "ceph", "-o")
			k2s.VerifyAddonIsEnabled("storage", "ceph")
		})
	})
})
