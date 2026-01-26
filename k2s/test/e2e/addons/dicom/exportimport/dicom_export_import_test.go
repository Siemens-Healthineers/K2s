// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package dicomexportimport

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

func TestDicomExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "dicom Addon Export/Import Tests", Label("addon", "addon-medical", "acceptance", "internet-required", "setup-required", "invasive", "dicom", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "dicom-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	addon = exportimport.GetAddonByName(allAddons, "dicom")
	Expect(addon).NotTo(BeNil(), "dicom addon should exist")

	impl = exportimport.GetImplementation(addon, "dicom")
	Expect(impl).NotTo(BeNil(), "dicom implementation should exist")

	k2s = dsl.NewK2s(suite)

	GinkgoWriter.Println("Using control-plane node IP address <", controlPlaneIpAddress, ">")
})

var _ = AfterSuite(func(ctx context.Context) {
	exportimport.CleanupExportedFiles(exportPath, exportedZipFile)
	suite.TearDown(ctx)
})

var _ = Describe("dicom addon export and import", Ordered, func() {
	Describe("export dicom addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports dicom addon to versioned zip file", func(ctx context.Context) {
			exportedZipFile = exportimport.ExportAddon(ctx, suite, "dicom", "", exportPath)

			_, err := os.Stat(exportedZipFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported zip file should exist")
		})

		It("contains dicom addon folder with correct structure", func(ctx context.Context) {
			extractedAddonsDir := exportimport.ExtractZip(ctx, suite, exportedZipFile, exportPath)

			expectedDirName := exportimport.GetExpectedDirName("dicom", "dicom")
			exportimport.VerifyExportedZipStructure(extractedAddonsDir, expectedDirName)
		})

		It("all resources have been exported", func(ctx context.Context) {
			expectedDirName := exportimport.GetExpectedDirName("dicom", "dicom")
			addonDir := filepath.Join(exportPath, "addons", expectedDirName)

			exportimport.VerifyExportedImages(suite, addonDir, impl)
			exportimport.VerifyExportedPackages(addonDir, impl)
		})

		It("version.info contains CD-friendly information", func(ctx context.Context) {
			expectedDirName := exportimport.GetExpectedDirName("dicom", "dicom")
			addonDir := filepath.Join(exportPath, "addons", expectedDirName)

			exportimport.VerifyVersionInfo(addonDir, expectedDirName)
		})
	})

	Describe("clean up dicom resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("no debian packages available before import", func(ctx context.Context) {
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import dicom addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.ImportAddon(ctx, suite, exportedZipFile)
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, exportedZipFile)
		})

		It("debian packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedDebPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("images available after import", func(ctx context.Context) {
			exportimport.VerifyImportedImages(ctx, suite, k2s, impl)
		})

		It("linux curl packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedLinuxCurlPackages(ctx, suite, impl, controlPlaneIpAddress)
		})

		It("windows curl packages available after import", func(ctx context.Context) {
			exportimport.VerifyImportedWindowsCurlPackages(suite, impl)
		})
	})
})
