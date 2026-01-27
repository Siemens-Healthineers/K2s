// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package smbexportimport

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
	exportedZipFile       string
	controlPlaneIpAddress string
	addon                 *addons.Addon
	impl                  *addons.Implementation
)

func TestStorageSmbExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage smb Addon Export/Import Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "storage-smb", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("STORAGE SMB EXPORT/IMPORT TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "storage-smb-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	GinkgoWriter.Printf("[Setup] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[Setup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Setup] Control plane IP: %s\n", controlPlaneIpAddress)

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	GinkgoWriter.Printf("[Setup] Total addons available: %d\n", len(allAddons))

	addon = exportimport.GetAddonByName(allAddons, "storage")
	Expect(addon).NotTo(BeNil(), "storage addon should exist")
	GinkgoWriter.Printf("[Setup] Found addon: %s\n", addon.Metadata.Name)

	impl = exportimport.GetImplementation(addon, "smb")
	Expect(impl).NotTo(BeNil(), "smb implementation should exist")
	GinkgoWriter.Printf("[Setup] Found implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Setup] Export directory name: %s\n", impl.ExportDirectoryName)

	k2s = dsl.NewK2s(suite)

	GinkgoWriter.Println("[Setup] Setup complete")
	GinkgoWriter.Println("========================================")
})

var _ = AfterSuite(func(ctx context.Context) {
	exportimport.CleanupExportedFiles(exportPath, exportedZipFile)
	suite.TearDown(ctx)
})

var _ = Describe("storage smb addon export and import", Ordered, func() {
	Describe("export storage smb addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports storage smb addon to versioned zip file", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: exports storage smb addon to versioned zip file")
			exportedZipFile = exportimport.ExportAddon(ctx, suite, "storage", "smb", exportPath)

			GinkgoWriter.Printf("[Test] Verifying exported ZIP file exists: %s\n", exportedZipFile)
			info, err := os.Stat(exportedZipFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported zip file should exist at %s", exportedZipFile)
			GinkgoWriter.Printf("[Test] ZIP file verified: %d bytes\n", info.Size())
		})

		It("contains storage smb addon folder with correct structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: contains storage smb addon folder with correct structure")
			extractedAddonsDir := exportimport.ExtractZip(ctx, suite, exportedZipFile, exportPath)

			expectedDirName := exportimport.GetExpectedDirName("storage", "smb")
			GinkgoWriter.Printf("[Test] Expected directory name: %s\n", expectedDirName)
			exportimport.VerifyExportedZipStructure(extractedAddonsDir, expectedDirName)
		})

		It("all resources have been exported", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported")
			expectedDirName := exportimport.GetExpectedDirName("storage", "smb")
			addonDir := filepath.Join(exportPath, "addons", expectedDirName)
			GinkgoWriter.Printf("[Test] Addon dir: %s\n", addonDir)

			exportimport.VerifyExportedImages(suite, addonDir, impl)
			exportimport.VerifyExportedPackages(addonDir, impl)
		})

		It("version.info contains CD-friendly information", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: version.info contains CD-friendly information")
			expectedDirName := exportimport.GetExpectedDirName("storage", "smb")
			addonDir := filepath.Join(exportPath, "addons", expectedDirName)
			GinkgoWriter.Printf("[Test] Addon dir: %s\n", addonDir)

			exportimport.VerifyVersionInfo(addonDir, expectedDirName)
		})
	})

	Describe("clean up storage smb resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("no debian packages available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no debian packages available before import")
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import storage smb addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.ImportAddon(ctx, suite, exportedZipFile)
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, exportedZipFile)
		})

		It("debian packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: debian packages available after import")
			exportimport.VerifyImportedDebPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("images available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: images available after import")
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})

		It("linux curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: linux curl packages available after import")
			exportimport.VerifyImportedLinuxCurlPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("windows curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: windows curl packages available after import")
			exportimport.VerifyImportedWindowsCurlPackages(suite, impl)
		})
	})
})
