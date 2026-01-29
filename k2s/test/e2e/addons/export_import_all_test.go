// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package addons

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

// This test file focuses on cross-addon integration tests for "export all addons" functionality.
// Per-addon export/import tests are located in each addon's directory (e.g., dashboard/dashboard_export_import_test.go).

const testClusterTimeout = time.Minute * 120

var (
	suite           *framework.K2sTestSuite
	linuxOnly       bool
	exportPath      string
	allAddons       addons.Addons
	exportedOciFile string

	linuxTestContainers   []string
	windowsTestContainers []string

	controlPlaneIpAddress string

	k2s        *dsl.K2s
	testFailed = false
)

func TestExportImportAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Export and Import Addons Functional Tests", Label("functional", "acceptance", "internet-required", "setup-required", "invasive", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("EXPORT/IMPORT ALL ADDONS TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp")
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
	allAddons = suite.AddonsAdditionalInfo().AllAddons()

	windowsTestContainers = []string{
		"shsk2s.azurecr.io/diskwriter:v1.2.0",
	}
	linuxTestContainers = []string{
		"shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0",
		"docker.io/curlimages/curl:8.5.0",
	}

	controlPlaneIpAddress = suite.SetupInfo().Config.ControlPlane().IpAddress()

	GinkgoWriter.Printf("[Setup] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[Setup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Setup] Control plane IP: %s\n", controlPlaneIpAddress)
	GinkgoWriter.Printf("[Setup] Linux-only mode: %v\n", linuxOnly)
	GinkgoWriter.Printf("[Setup] Total addons available: %d\n", len(allAddons))

	for i, a := range allAddons {
		GinkgoWriter.Printf("[Setup]   [%d] %s (%d implementations)\n", i, a.Metadata.Name, len(a.Spec.Implementations))
	}

	k2s = dsl.NewK2s(suite)

	GinkgoWriter.Println("[Setup] Setup complete")
	GinkgoWriter.Println("========================================")
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("export and import all addons and make sure all artifacts are available afterwards", Ordered, func() {
	if linuxOnly {
		Skip("Linux-only setup")
	}

	Describe("export all addons", func() {
		BeforeAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "artifacts")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}

			GinkgoWriter.Printf("Exporting all addons to %s", exportPath)
			suite.K2sCli().MustExec(ctx, "addons", "export", "-d", exportPath, "-o")

			// Find the exported OCI file
			files, err := filepath.Glob(filepath.Join(exportPath, "K2s-*-addons-all.oci.tar"))
			Expect(err).To(BeNil())
			Expect(len(files)).To(Equal(1), "Should create exactly one versioned OCI tar file")
			exportedOciFile = files[0]
			GinkgoWriter.Printf("Exported OCI file: %s\n", exportedOciFile)
		})

		AfterAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "artifacts")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}
		})

		It("addons are exported to versioned OCI tar file", func(ctx context.Context) {
			Expect(exportedOciFile).NotTo(BeEmpty(), "exportedOciFile should be set")
			_, err := os.Stat(exportedOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse(), "Exported OCI file should exist at %s", exportedOciFile)
		})

		It("contains a folder for every exported addon with OCI layered structure", func(ctx context.Context) {
			suite.Cli("tar").MustExec(ctx, "-xf", exportedOciFile, "-C", exportPath)

			_, err := os.Stat(filepath.Join(exportPath, "artifacts"))
			Expect(os.IsNotExist(err)).To(BeFalse())

			_, err = os.Stat(filepath.Join(exportPath, "artifacts", "addons.json"))
			Expect(os.IsNotExist(err)).To(BeFalse(), "addons.json metadata file should exist")

			_, err = os.Stat(filepath.Join(exportPath, "artifacts", "index.json"))
			Expect(os.IsNotExist(err)).To(BeFalse(), "index.json OCI index file should exist")
			exportedAddonsDir, err := os.ReadDir(filepath.Join(exportPath, "artifacts"))
			Expect(err).To(BeNil())

			exportedAddonsDir = lo.Filter(exportedAddonsDir, func(x fs.DirEntry, index int) bool {
				return x.IsDir() && x.Name() != "hooks"
			})

			exportedAddons := lo.Map(exportedAddonsDir, func(x fs.DirEntry, index int) string {
				return x.Name()
			})

			GinkgoWriter.Println("Exported addons:", exportedAddons)

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					var expectedDirName string
					if i.Name != a.Metadata.Name {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name+"_"+i.Name, " ", "_")
					} else {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name, " ", "_")
					}

					GinkgoWriter.Println("Checking addon:", a.Metadata.Name, ", implementation:", i.Name, ", expected directory name:", expectedDirName)

					contains := slices.Contains(exportedAddons, expectedDirName)
					Expect(contains).To(BeTrue(), "Expected directory %s not found in exported addons", expectedDirName)
				}
			}

			for _, e := range exportedAddons {
				addonsDir := filepath.Join(exportPath, "artifacts", e)

				Expect(sos.IsEmptyDir(addonsDir)).To(BeFalse(), "addon directory should not be empty for addon %s", e)

				// Check for OCI manifest
				ociManifestPath := filepath.Join(addonsDir, "oci-manifest.json")
				_, err = os.Stat(ociManifestPath)
				Expect(os.IsNotExist(err)).To(BeFalse(), "oci-manifest.json should exist for addon %s", e)

				// Check for addon.manifest.yaml (OCI config)
				addonManifestPath := filepath.Join(addonsDir, "addon.manifest.yaml")
				_, err = os.Stat(addonManifestPath)
				Expect(os.IsNotExist(err)).To(BeFalse(), "addon.manifest.yaml should exist for addon %s", e)

				// Check for scripts layer
				scriptsLayerPath := filepath.Join(addonsDir, "scripts.tar.gz")
				_, err = os.Stat(scriptsLayerPath)
				Expect(os.IsNotExist(err)).To(BeFalse(), "scripts.tar.gz layer should exist for addon %s", e)
			}
		})

		It("all resources have been exported as OCI layers", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported as OCI layers")
			GinkgoWriter.Printf("[Test] Checking %d addons\n", len(allAddons))

			for addonIdx, a := range allAddons {
				for implIdx, i := range a.Spec.Implementations {
					var expectedDirName string
					if i.Name != a.Metadata.Name {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name+"_"+i.Name, " ", "_")
					} else {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name, " ", "_")
					}

					GinkgoWriter.Printf("[Test] [%d.%d] Addon: %s, Implementation: %s, Expected Dir: %s\n", addonIdx, implIdx, a.Metadata.Name, i.Name, expectedDirName)
					addonExportDir := filepath.Join(exportPath, "artifacts", expectedDirName)

					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).ToNot(HaveOccurred())
					GinkgoWriter.Printf("[Test]   Expected images: %d\n", len(images))

					// Check for image layers (consolidated into single tar files per platform)
					if len(images) > 0 {
						linuxImagesLayer := filepath.Join(addonExportDir, "images-linux.tar")
						windowsImagesLayer := filepath.Join(addonExportDir, "images-windows.tar")
						linuxExists := false
						windowsExists := false
						if _, err := os.Stat(linuxImagesLayer); err == nil {
							linuxExists = true
							GinkgoWriter.Println("[Test]   Found images-linux.tar layer")
						}
						if _, err := os.Stat(windowsImagesLayer); err == nil {
							windowsExists = true
							GinkgoWriter.Println("[Test]   Found images-windows.tar layer")
						}
						Expect(linuxExists || windowsExists).To(BeTrue(),
							"Expected at least one image layer (images-linux.tar or images-windows.tar) for addon %s with %d images", expectedDirName, len(images))
					}

					// Check OCI manifest exists
					_, err = os.Stat(filepath.Join(addonExportDir, "oci-manifest.json"))
					Expect(os.IsNotExist(err)).To(BeFalse(), "oci-manifest.json should exist for addon %s", expectedDirName)
					GinkgoWriter.Println("[Test]   oci-manifest.json exists")

					// Check for packages layer if offline_usage is defined
					hasLinuxPackages := len(i.OfflineUsage.LinuxResources.CurlPackages) > 0 || len(i.OfflineUsage.LinuxResources.DebPackages) > 0
					hasWindowsPackages := len(i.OfflineUsage.WindowsResources.CurlPackages) > 0
					if hasLinuxPackages || hasWindowsPackages {
						packagesLayer := filepath.Join(addonExportDir, "packages.tar.gz")
						_, err = os.Stat(packagesLayer)
						Expect(os.IsNotExist(err)).To(BeFalse(), "packages.tar.gz should exist for addon %s with offline packages", expectedDirName)
						GinkgoWriter.Printf("[Test]   packages.tar.gz exists (Linux packages: %d, Windows packages: %d)\n",
							len(i.OfflineUsage.LinuxResources.CurlPackages)+len(i.OfflineUsage.LinuxResources.DebPackages),
							len(i.OfflineUsage.WindowsResources.CurlPackages))
					}

					GinkgoWriter.Printf("[Test]   OK: All OCI layers verified for %s\n", expectedDirName)
				}
			}
			GinkgoWriter.Println("[Test] All addons OCI layers verified successfully")
		})

		It("metadata files contain correct OCI information", func(ctx context.Context) {
			addonsJsonPath := filepath.Join(exportPath, "artifacts", "addons.json")
			addonsJsonBytes, err := os.ReadFile(addonsJsonPath)
			Expect(err).To(BeNil())
			Expect(string(addonsJsonBytes)).To(ContainSubstring("k2sVersion"))
			Expect(string(addonsJsonBytes)).To(ContainSubstring("exportType"))
			Expect(string(addonsJsonBytes)).To(ContainSubstring("artifactFormat"))
			Expect(string(addonsJsonBytes)).To(ContainSubstring("addons"))

			indexJsonPath := filepath.Join(exportPath, "artifacts", "index.json")
			indexJsonBytes, err := os.ReadFile(indexJsonPath)
			Expect(err).To(BeNil())
			Expect(string(indexJsonBytes)).To(ContainSubstring("schemaVersion"))
			Expect(string(indexJsonBytes)).To(ContainSubstring("mediaType"))
			Expect(string(indexJsonBytes)).To(ContainSubstring("vnd.k2s.version"))
			Expect(string(indexJsonBytes)).To(ContainSubstring("vnd.k2s.addon.count"))
		})

		It("oci-manifest.json files contain proper OCI structure", func(ctx context.Context) {
			exportedAddonsDir, err := os.ReadDir(filepath.Join(exportPath, "artifacts"))
			Expect(err).To(BeNil())

			addonDirs := []string{}
			for _, entry := range exportedAddonsDir {
				if entry.IsDir() {
					addonDirs = append(addonDirs, entry.Name())
				}
			}

			for _, addonDir := range addonDirs {
				ociManifestPath := filepath.Join(exportPath, "artifacts", addonDir, "oci-manifest.json")
				ociManifestBytes, err := os.ReadFile(ociManifestPath)
				Expect(err).To(BeNil(), "should be able to read oci-manifest.json for addon %s", addonDir)

				Expect(string(ociManifestBytes)).To(ContainSubstring("schemaVersion"))
				Expect(string(ociManifestBytes)).To(ContainSubstring("mediaType"))
				Expect(string(ociManifestBytes)).To(ContainSubstring("layers"))
				Expect(string(ociManifestBytes)).To(ContainSubstring("vnd.k2s.addon.name"))
				Expect(string(ociManifestBytes)).To(ContainSubstring("org.opencontainers.image.version"))

				GinkgoWriter.Printf("OCI manifest for %s verified", addonDir)
			}
		})
	})

	Describe("clean up downloaded resources", func() {
		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== CLEAN UP ALL ADDONS RESOURCES - BeforeAll START ===")

			GinkgoWriter.Println("[BeforeAll] Cleaning images with 'k2s image clean -o'...")
			suite.K2sCli().Exec(ctx, "image", "clean", "-o")
			GinkgoWriter.Println("[BeforeAll] Image cleanup completed")

			GinkgoWriter.Printf("[BeforeAll] Removing downloaded debian packages for %d addons...\n", len(allAddons))
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					GinkgoWriter.Printf("[BeforeAll]   Removing debian packages for %s/%s (dir: %s)\n", a.Metadata.Name, i.Name, i.ExportDirectoryName)
					suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("sudo rm -rf .%s", i.ExportDirectoryName))
				}
			}
			GinkgoWriter.Println("[BeforeAll] Debian packages cleanup completed")
			GinkgoWriter.Println("=== CLEAN UP ALL ADDONS RESOURCES - BeforeAll END ===")
		})

		It("no debian packages available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no debian packages available before import")
			GinkgoWriter.Printf("[Test] Checking %d addons for debian package directories...\n", len(allAddons))

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					GinkgoWriter.Printf("[Test]   Checking %s/%s (dir: .%s) does not exist...\n", a.Metadata.Name, i.Name, i.ExportDirectoryName)
					suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s ]", i.ExportDirectoryName))
					GinkgoWriter.Printf("[Test]   OK: .%s does not exist\n", i.ExportDirectoryName)
				}
			}
			GinkgoWriter.Println("[Test] Verified: No debian package directories exist")
		})

		It("no images available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no images available before import")

			images := k2s.GetNonK8sImagesFromNodes(ctx)
			GinkgoWriter.Printf("[Test] Found %d images on nodes\n", len(images))
			for idx, img := range images {
				GinkgoWriter.Printf("[Test]   [%d] %s\n", idx, img)
			}

			Expect(images).To(BeEmpty())
			GinkgoWriter.Println("[Test] Verified: No images present before import")
		})
	})

	Describe("import all addons", func() {
		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== IMPORT ALL ADDONS - BeforeAll START ===")
			GinkgoWriter.Printf("[BeforeAll] Importing from OCI tar file: %s\n", exportedOciFile)
			suite.K2sCli().MustExec(ctx, "addons", "import", "-z", exportedOciFile)
			GinkgoWriter.Println("[BeforeAll] Import completed")
			GinkgoWriter.Println("=== IMPORT ALL ADDONS - BeforeAll END ===")
		}, NodeTimeout(time.Minute*30))

		AfterAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== IMPORT ALL ADDONS - AfterAll START ===")
			if _, err := os.Stat(exportPath); !os.IsNotExist(err) {
				GinkgoWriter.Printf("[AfterAll] Removing export path: %s\n", exportPath)
				os.RemoveAll(exportPath)
			}
			GinkgoWriter.Println("=== IMPORT ALL ADDONS - AfterAll END ===")
		})

		It("debian packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: debian packages available after import")
			GinkgoWriter.Printf("[Test] Checking debian packages for %d addons...\n", len(allAddons))

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					GinkgoWriter.Printf("[Test]   Checking %s/%s - %d debian packages\n", a.Metadata.Name, i.Name, len(i.OfflineUsage.LinuxResources.DebPackages))
					for pkgIdx, pkg := range i.OfflineUsage.LinuxResources.DebPackages {
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s/%s ]", i.ExportDirectoryName, pkg))
						GinkgoWriter.Printf("[Test]     [%d] OK: %s\n", pkgIdx, pkg)
					}
				}
			}
			GinkgoWriter.Println("[Test] All debian packages verified")
		})

		It("images available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: images available after import")

			importedImages := k2s.GetNonK8sImagesFromNodes(ctx)
			GinkgoWriter.Printf("[Test] Found %d non-K8s images on nodes\n", len(importedImages))
			for idx, img := range importedImages {
				GinkgoWriter.Printf("[Test]   [%d] %s\n", idx, img)
			}

			GinkgoWriter.Printf("[Test] Verifying images for %d addons...\n", len(allAddons))
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).To(BeNil())
					GinkgoWriter.Printf("[Test]   Checking %s/%s - %d expected images\n", a.Metadata.Name, i.Name, len(images))

					for imgIdx, img := range images {
						contains := slices.ContainsFunc(importedImages, func(image string) bool {
							return strings.Contains(image, img)
						})
						if contains {
							GinkgoWriter.Printf("[Test]     [%d] OK: %s\n", imgIdx, img)
						} else {
							GinkgoWriter.Printf("[Test]     [%d] MISSING: %s\n", imgIdx, img)
						}
						Expect(contains).To(BeTrue(), "Image %s should be available after import", img)
					}
				}
			}
			GinkgoWriter.Println("[Test] All images verified")
		})

		It("linux curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: linux curl packages available after import")
			GinkgoWriter.Printf("[Test] Checking linux curl packages for %d addons...\n", len(allAddons))

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					GinkgoWriter.Printf("[Test]   Checking %s/%s - %d linux curl packages\n", a.Metadata.Name, i.Name, len(i.OfflineUsage.LinuxResources.CurlPackages))
					for pkgIdx, pkg := range i.OfflineUsage.LinuxResources.CurlPackages {
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -f %s ]", pkg.Destination))
						GinkgoWriter.Printf("[Test]     [%d] OK: %s\n", pkgIdx, pkg.Destination)
					}
				}
			}
			GinkgoWriter.Println("[Test] All linux curl packages verified")
		})

		It("windows curl packages available after import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: windows curl packages available after import")
			GinkgoWriter.Printf("[Test] Checking windows curl packages for %d addons...\n", len(allAddons))

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					GinkgoWriter.Printf("[Test]   Checking %s/%s - %d windows curl packages\n", a.Metadata.Name, i.Name, len(i.OfflineUsage.WindowsResources.CurlPackages))
					for pkgIdx, p := range i.OfflineUsage.WindowsResources.CurlPackages {
						pkgPath := filepath.Join(suite.RootDir(), p.Destination)
						info, err := os.Stat(pkgPath)
						if os.IsNotExist(err) {
							GinkgoWriter.Printf("[Test]     [%d] MISSING: %s\n", pkgIdx, pkgPath)
						} else {
							GinkgoWriter.Printf("[Test]     [%d] OK: %s (%d bytes)\n", pkgIdx, pkgPath, info.Size())
						}
						Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist at %s", p.Destination, pkgPath)
					}
				}
			}
			GinkgoWriter.Println("[Test] All windows curl packages verified")
		})

		It("tar files are excluded during import but other content is imported", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: tar files are excluded during import but other content is imported")
			addonsBaseDir := filepath.Join(suite.RootDir(), "addons")
			GinkgoWriter.Printf("[Test] Checking addons directory: %s\n", addonsBaseDir)

			addonsDirs, err := os.ReadDir(addonsBaseDir)
			Expect(err).To(BeNil())
			GinkgoWriter.Printf("[Test] Found %d addon directories\n", len(addonsDirs))

			for _, addonDir := range addonsDirs {
				if !addonDir.IsDir() {
					continue
				}

				addonPath := filepath.Join(suite.RootDir(), "addons", addonDir.Name())
				GinkgoWriter.Printf("[Test] Checking addon: %s\n", addonDir.Name())

				err := filepath.WalkDir(addonPath, func(path string, d os.DirEntry, err error) error {
					if err != nil {
						return err
					}

					if !d.IsDir() && strings.HasSuffix(d.Name(), ".tar") {
						GinkgoWriter.Printf("[Test] ERROR: Found unexpected .tar file: %s\n", path)
						Fail("Found .tar file in addon directory: " + path)
					}

					return nil
				})

				Expect(err).To(BeNil())

				manifestPath := filepath.Join(addonPath, "addon.manifest.yaml")
				if _, err := os.Stat(manifestPath); err == nil {
					GinkgoWriter.Printf("[Test] OK: Manifest exists for addon: %s\n", addonDir.Name())
				}
			}

			GinkgoWriter.Println("[Test] Verified: No .tar files found in addon directories after import")
		})

		It("version.info files are processed and removed during import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: version.info files are processed and removed during import")
			addonsBaseDir := filepath.Join(suite.RootDir(), "addons")
			GinkgoWriter.Printf("[Test] Checking addons directory: %s\n", addonsBaseDir)

			addonsDirs, err := os.ReadDir(addonsBaseDir)
			Expect(err).To(BeNil())
			GinkgoWriter.Printf("[Test] Found %d addon directories\n", len(addonsDirs))

			for _, addonDir := range addonsDirs {
				if !addonDir.IsDir() {
					continue
				}

				addonPath := filepath.Join(suite.RootDir(), "addons", addonDir.Name())
				GinkgoWriter.Printf("[Test] Checking addon: %s\n", addonDir.Name())

				err := filepath.WalkDir(addonPath, func(path string, d os.DirEntry, err error) error {
					if err != nil {
						return err
					}

					if !d.IsDir() && d.Name() == "version.info" {
						GinkgoWriter.Printf("[Test] ERROR: Found unexpected version.info file: %s\n", path)
						Fail("Found version.info file in final addon directory: " + path)
					}

					return nil
				})

				Expect(err).To(BeNil())
				GinkgoWriter.Printf("[Test] OK: No version.info in %s\n", addonDir.Name())
			}

			GinkgoWriter.Println("[Test] Verified: No version.info files found in final addon directories after import")
		})

		It("manifest merging preserves multiple implementations", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: manifest merging preserves multiple implementations")

			// Check ingress addon
			ingressManifestPath := filepath.Join(suite.RootDir(), "addons", "ingress", "addon.manifest.yaml")
			GinkgoWriter.Printf("[Test] Checking ingress manifest: %s\n", ingressManifestPath)
			if _, err := os.Stat(ingressManifestPath); err == nil {
				manifestContent, err := os.ReadFile(ingressManifestPath)
				Expect(err).To(BeNil())
				manifestStr := string(manifestContent)
				GinkgoWriter.Printf("[Test] Ingress manifest size: %d bytes\n", len(manifestContent))
				GinkgoWriter.Printf("[Test] Ingress manifest content (first 1000 chars):\n%s\n", manifestStr[:min(1000, len(manifestStr))])

				Expect(manifestStr).To(ContainSubstring("nginx"), "Ingress manifest should contain nginx implementation")
				GinkgoWriter.Println("[Test] OK: nginx implementation found")
				Expect(manifestStr).To(ContainSubstring("traefik"), "Ingress manifest should contain traefik implementation")
				GinkgoWriter.Println("[Test] OK: traefik implementation found")

				Expect(manifestStr).To(ContainSubstring("SPDX-FileCopyrightText"), "Manifest should preserve SPDX header")
				Expect(manifestStr).To(ContainSubstring("SPDX-License-Identifier"), "Manifest should preserve license identifier")
				GinkgoWriter.Println("[Test] OK: SPDX headers preserved")

				GinkgoWriter.Println("[Test] Verified: Ingress manifest contains both nginx and traefik implementations")
			} else {
				GinkgoWriter.Printf("[Test] SKIP: Ingress manifest not found at %s\n", ingressManifestPath)
			}

			// Also verify rollout addon has both implementations
			rolloutManifestPath := filepath.Join(suite.RootDir(), "addons", "rollout", "addon.manifest.yaml")
			GinkgoWriter.Printf("[Test] Checking rollout manifest: %s\n", rolloutManifestPath)
			if _, err := os.Stat(rolloutManifestPath); err == nil {
				manifestContent, err := os.ReadFile(rolloutManifestPath)
				Expect(err).To(BeNil())
				manifestStr := string(manifestContent)
				GinkgoWriter.Printf("[Test] Rollout manifest size: %d bytes\n", len(manifestContent))
				GinkgoWriter.Printf("[Test] Rollout manifest content (first 1000 chars):\n%s\n", manifestStr[:min(1000, len(manifestStr))])

				Expect(manifestStr).To(ContainSubstring("argocd"), "Rollout manifest should contain argocd implementation")
				GinkgoWriter.Println("[Test] OK: argocd implementation found")
				Expect(manifestStr).To(ContainSubstring("fluxcd"), "Rollout manifest should contain fluxcd implementation")
				GinkgoWriter.Println("[Test] OK: fluxcd implementation found")

				GinkgoWriter.Println("[Test] Verified: Rollout manifest contains both argocd and fluxcd implementations")
			} else {
				GinkgoWriter.Printf("[Test] SKIP: Rollout manifest not found at %s\n", rolloutManifestPath)
			}
		})
	})
})
