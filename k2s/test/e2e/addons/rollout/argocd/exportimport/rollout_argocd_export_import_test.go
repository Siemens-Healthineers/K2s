// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package argocdexportimport

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

func TestRolloutArgocdExportImport(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "rollout argocd Addon Export/Import Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "rollout-argocd", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("ROLLOUT ARGOCD EXPORT/IMPORT TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(exportImportTestTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp", "rollout-argocd-export-test")
	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	GinkgoWriter.Printf("[Setup] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[Setup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Setup] Control plane IP: %s\n", controlPlaneIpAddress)

	allAddons := suite.AddonsAdditionalInfo().AllAddons()
	GinkgoWriter.Printf("[Setup] Total addons available: %d\n", len(allAddons))

	addon = exportimport.GetAddonByName(allAddons, "rollout")
	Expect(addon).NotTo(BeNil(), "rollout addon should exist")
	GinkgoWriter.Printf("[Setup] Found addon: %s\n", addon.Metadata.Name)

	impl = exportimport.GetImplementation(addon, "argocd")
	Expect(impl).NotTo(BeNil(), "argocd implementation should exist")
	GinkgoWriter.Printf("[Setup] Found implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Setup] Export directory name: %s\n", impl.ExportDirectoryName)

	k2s = dsl.NewK2s(suite)

	GinkgoWriter.Println("[Setup] Setup complete")
	GinkgoWriter.Println("========================================")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}
	if !testFailed {
		exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
	}
	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("rollout argocd addon export and import", Ordered, func() {
	Describe("export rollout argocd addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, "")
		})

		It("exports rollout argocd addon to versioned OCI tar file", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: exports rollout argocd addon to versioned OCI tar file")
			exportedOciFile = exportimport.ExportAddon(ctx, suite, "rollout", "argocd", exportPath)

			GinkgoWriter.Printf("[Test] Verifying exported OCI tar file exists: %s\n", exportedOciFile)
			info, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "exported OCI tar file should exist at %s", exportedOciFile)
			GinkgoWriter.Printf("[Test] OCI tar file verified: %d bytes\n", info.Size())
		})

		It("contains rollout addon folder with correct OCI structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: contains rollout addon folder with correct OCI structure")
			extractedArtifactsDir := exportimport.ExtractOciTar(ctx, suite, exportedOciFile, exportPath)

			expectedDirName := exportimport.GetExpectedDirName("rollout", "argocd")
			GinkgoWriter.Printf("[Test] Expected directory name: %s\n", expectedDirName)
			exportimport.VerifyExportedOciStructure(extractedArtifactsDir, expectedDirName)
		})

		It("all resources have been exported", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported")
			expectedDirName := exportimport.GetExpectedDirName("rollout", "argocd")
			addonDir := filepath.Join(exportPath, "artifacts", expectedDirName)
			GinkgoWriter.Printf("[Test] Addon dir: %s\n", addonDir)

			exportimport.VerifyExportedImages(suite, addonDir, impl)
			exportimport.VerifyExportedPackages(addonDir, impl)
		})

		It("oci-manifest.json contains proper OCI structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: oci-manifest.json contains proper OCI structure")
			expectedDirName := exportimport.GetExpectedDirName("rollout", "argocd")
			addonDir := filepath.Join(exportPath, "artifacts", expectedDirName)
			GinkgoWriter.Printf("[Test] Addon dir: %s\n", addonDir)

			exportimport.VerifyOciManifest(addonDir, expectedDirName)
		})
	})

	Describe("clean up rollout argocd resources", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.CleanAddonResources(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})

		It("no debian packages available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no debian packages available before import")
			exportimport.VerifyResourcesCleanedUp(ctx, suite, k2s, impl, controlPlaneIpAddress)
		})
	})

	Describe("import rollout argocd addon", func() {
		BeforeAll(func(ctx context.Context) {
			exportimport.ImportAddon(ctx, suite, exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			exportimport.CleanupExportedFiles(exportPath, exportedOciFile)
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
