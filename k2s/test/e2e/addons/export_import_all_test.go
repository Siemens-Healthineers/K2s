// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
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
	exportedZipFile string

	controlPlaneIpAddress string

	k2s *dsl.K2s
)

func TestExportImportAllAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Export and Import All Addons Integration Tests", Label("functional", "acceptance", "internet-required", "setup-required", "invasive", "export-import-all", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	GinkgoWriter.Println("========================================")
	GinkgoWriter.Println("EXPORT/IMPORT ALL ADDONS TEST - SETUP")
	GinkgoWriter.Println("========================================")

	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp")
	linuxOnly = suite.SetupInfo().RuntimeConfig.InstallConfig().LinuxOnly()
	allAddons = suite.AddonsAdditionalInfo().AllAddons()

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
	suite.TearDown(ctx)
})

var _ = Describe("export and import all addons integration test", Ordered, func() {
	if linuxOnly {
		Skip("Linux-only setup")
	}

	Describe("export all addons", func() {
		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== EXPORT ALL ADDONS - BeforeAll START ===")
			extractedFolder := filepath.Join(exportPath, "addons")
			GinkgoWriter.Printf("[BeforeAll] Checking for existing extracted folder: %s\n", extractedFolder)
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				GinkgoWriter.Println("[BeforeAll] Removing existing extracted folder...")
				os.RemoveAll(extractedFolder)
			}

			GinkgoWriter.Printf("[BeforeAll] Exporting all addons to %s\n", exportPath)
			suite.K2sCli().MustExec(ctx, "addons", "export", "-d", exportPath, "-o")
			GinkgoWriter.Println("=== EXPORT ALL ADDONS - BeforeAll END ===")
		})

		AfterAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "addons")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}
		})

		It("addons are exported to versioned zip file", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: addons are exported to versioned zip file")
			pattern := filepath.Join(exportPath, "K2s-*-addons-all.zip")
			GinkgoWriter.Printf("[Test] Looking for ZIP file matching pattern: %s\n", pattern)

			files, err := filepath.Glob(pattern)
			Expect(err).To(BeNil())
			GinkgoWriter.Printf("[Test] Found %d matching ZIP file(s)\n", len(files))
			for i, f := range files {
				GinkgoWriter.Printf("[Test]   [%d] %s\n", i, f)
			}
			Expect(len(files)).To(Equal(1), "Should create exactly one versioned zip file")

			exportedZipFile = files[0]
			info, err := os.Stat(exportedZipFile)
			Expect(os.IsNotExist(err)).To(BeFalse())
			GinkgoWriter.Printf("[Test] ZIP file size: %d bytes\n", info.Size())
		})

		It("contains a folder for every exported addon with flattened structure and version info", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: contains a folder for every exported addon with flattened structure and version info")
			GinkgoWriter.Printf("[Test] Extracting ZIP file: %s\n", exportedZipFile)
			suite.Cli("tar").MustExec(ctx, "-xf", exportedZipFile, "-C", exportPath)
			GinkgoWriter.Println("[Test] Extraction completed")

			addonsDir := filepath.Join(exportPath, "addons")
			_, err := os.Stat(addonsDir)
			Expect(os.IsNotExist(err)).To(BeFalse(), "addons directory should exist at %s", addonsDir)
			GinkgoWriter.Printf("[Test] Addons directory exists: %s\n", addonsDir)

			addonsJsonPath := filepath.Join(exportPath, "addons", "addons.json")
			_, err = os.Stat(addonsJsonPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "addons.json metadata file should exist at %s", addonsJsonPath)
			GinkgoWriter.Println("[Test] addons.json exists")

			versionJsonPath := filepath.Join(exportPath, "addons", "version.json")
			_, err = os.Stat(versionJsonPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "version.json metadata file should exist at %s", versionJsonPath)
			GinkgoWriter.Println("[Test] version.json exists")

			exportedAddonsDir, err := os.ReadDir(filepath.Join(exportPath, "addons"))
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
				addonsDir := filepath.Join(exportPath, "addons", e)

				Expect(sos.IsEmptyDir(addonsDir)).To(BeFalse(), "addon directory should not be empty for addon %s", e)

				versionInfoPath := filepath.Join(addonsDir, "version.info")
				_, err = os.Stat(versionInfoPath)
				Expect(os.IsNotExist(err)).To(BeFalse(), "version.info file should exist for addon %s", e)
			}
		})

		It("all resources have been exported for all addons", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported for all addons")
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
					addonExportDir := filepath.Join(exportPath, "addons", expectedDirName)

					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).ToNot(HaveOccurred())
					GinkgoWriter.Printf("[Test]   Expected images: %d\n", len(images))

					exportedImages, err := sos.GetFilesMatch(addonExportDir, "*.tar")
					Expect(err).ToNot(HaveOccurred())
					GinkgoWriter.Printf("[Test]   Found tar files: %d\n", len(exportedImages))
					Expect(len(exportedImages)).To(Equal(len(images)),
						"Expected %d tar files to match %d images for %s", len(images), len(images), expectedDirName)

					_, err = os.Stat(filepath.Join(addonExportDir, "version.info"))
					Expect(os.IsNotExist(err)).To(BeFalse(), "version.info should exist for addon %s", expectedDirName)
					GinkgoWriter.Println("[Test]   version.info exists")

					GinkgoWriter.Printf("[Test]   Checking %d linux curl packages\n", len(i.OfflineUsage.LinuxResources.CurlPackages))
					for _, lp := range i.OfflineUsage.LinuxResources.CurlPackages {
						_, err = os.Stat(filepath.Join(addonExportDir, "linuxpackages", filepath.Base(lp.Url)))
						Expect(os.IsNotExist(err)).To(BeFalse(), "Linux curl package %s should exist", lp.Url)
					}

					GinkgoWriter.Printf("[Test]   Checking %d debian packages\n", len(i.OfflineUsage.LinuxResources.DebPackages))
					for _, d := range i.OfflineUsage.LinuxResources.DebPackages {
						_, err = os.Stat(filepath.Join(addonExportDir, "debianpackages", d))
						Expect(os.IsNotExist(err)).To(BeFalse(), "Debian package %s should exist", d)
					}

					GinkgoWriter.Printf("[Test]   Checking %d windows curl packages\n", len(i.OfflineUsage.WindowsResources.CurlPackages))
					for _, wp := range i.OfflineUsage.WindowsResources.CurlPackages {
						_, err = os.Stat(filepath.Join(addonExportDir, "windowspackages", filepath.Base(wp.Url)))
						Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist", wp.Url)
					}
					GinkgoWriter.Printf("[Test]   OK: All resources verified for %s\n", expectedDirName)
				}
			}
			GinkgoWriter.Println("[Test] All addons verified successfully")
		})

		It("metadata files contain correct information", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: metadata files contain correct information")

			addonsJsonPath := filepath.Join(exportPath, "addons", "addons.json")
			GinkgoWriter.Printf("[Test] Reading addons.json: %s\n", addonsJsonPath)
			addonsJsonBytes, err := os.ReadFile(addonsJsonPath)
			Expect(err).To(BeNil())
			GinkgoWriter.Printf("[Test] addons.json size: %d bytes\n", len(addonsJsonBytes))
			GinkgoWriter.Printf("[Test] addons.json content (first 500 chars):\n%s\n", string(addonsJsonBytes)[:min(500, len(addonsJsonBytes))])

			Expect(string(addonsJsonBytes)).To(ContainSubstring("k2sVersion"))
			Expect(string(addonsJsonBytes)).To(ContainSubstring("exportType"))
			Expect(string(addonsJsonBytes)).To(ContainSubstring("addons"))

			versionJsonPath := filepath.Join(exportPath, "addons", "version.json")
			GinkgoWriter.Printf("[Test] Reading version.json: %s\n", versionJsonPath)
			versionJsonBytes, err := os.ReadFile(versionJsonPath)
			Expect(err).To(BeNil())
			GinkgoWriter.Printf("[Test] version.json content:\n%s\n", string(versionJsonBytes))

			Expect(string(versionJsonBytes)).To(ContainSubstring("k2sVersion"))
			Expect(string(versionJsonBytes)).To(ContainSubstring("exportType"))
			Expect(string(versionJsonBytes)).To(ContainSubstring("addonCount"))
			GinkgoWriter.Println("[Test] Metadata files verified")
		})

		It("version.info files contain CD-friendly information", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: version.info files contain CD-friendly information")

			exportedAddonsDir, err := os.ReadDir(filepath.Join(exportPath, "addons"))
			Expect(err).To(BeNil())

			addonDirs := []string{}
			for _, entry := range exportedAddonsDir {
				if entry.IsDir() {
					addonDirs = append(addonDirs, entry.Name())
				}
			}
			GinkgoWriter.Printf("[Test] Checking version.info in %d addon directories\n", len(addonDirs))

			for i, addonDir := range addonDirs {
				versionInfoPath := filepath.Join(exportPath, "addons", addonDir, "version.info")
				versionInfoBytes, err := os.ReadFile(versionInfoPath)
				Expect(err).To(BeNil(), "should be able to read version.info for addon %s", addonDir)

				versionInfo := string(versionInfoBytes)
				GinkgoWriter.Printf("[Test] [%d] %s - version.info content:\n%s\n", i, addonDir, versionInfo)

				Expect(versionInfo).To(ContainSubstring("addonName"), "version.info for %s should contain addonName", addonDir)
				Expect(versionInfo).To(ContainSubstring("implementationName"), "version.info for %s should contain implementationName", addonDir)
				Expect(versionInfo).To(ContainSubstring("k2sVersion"), "version.info for %s should contain k2sVersion", addonDir)
				Expect(versionInfo).To(ContainSubstring("exportDate"), "version.info for %s should contain exportDate", addonDir)
				Expect(versionInfo).To(ContainSubstring("exportType"), "version.info for %s should contain exportType", addonDir)
				GinkgoWriter.Printf("[Test] [%d] %s - OK\n", i, addonDir)
			}
			GinkgoWriter.Println("[Test] All version.info files verified")
		})
	})

	Describe("clean up downloaded resources for all addons", func() {
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
					suite.K2sCli().ExpectedExitCode(1).Exec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s ]", i.ExportDirectoryName))
					GinkgoWriter.Printf("[Test]   OK: .%s does not exist\n", i.ExportDirectoryName)
				}
			}
			GinkgoWriter.Println("[Test] Verified: No debian package directories exist")
		})

		It("no addon images available before import", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: no addon images available before import")

			currentImages := k2s.GetNonK8sImagesFromNodes(ctx)
			GinkgoWriter.Printf("[Test] Found %d images on nodes\n", len(currentImages))
			for idx, img := range currentImages {
				GinkgoWriter.Printf("[Test]   [%d] %s\n", idx, img)
			}

			// Verify that no addon-specific images are present
			GinkgoWriter.Printf("[Test] Checking that no addon images from %d addons are present...\n", len(allAddons))
			addonImagesFound := []string{}

			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					expectedImages, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).To(BeNil())

					for _, expectedImg := range expectedImages {
						for _, currentImg := range currentImages {
							if strings.Contains(currentImg, expectedImg) {
								addonImagesFound = append(addonImagesFound, expectedImg)
								GinkgoWriter.Printf("[Test]   FOUND addon image: %s (from %s/%s)\n", expectedImg, a.Metadata.Name, i.Name)
							}
						}
					}
				}
			}

			Expect(addonImagesFound).To(BeEmpty(), "No addon images should be present before import, but found: %v", addonImagesFound)
			GinkgoWriter.Println("[Test] Verified: No addon images present before import")
		})
	})

	Describe("import all addons and verify manifest merging", func() {
		BeforeAll(func(ctx context.Context) {
			GinkgoWriter.Println("=== IMPORT ALL ADDONS - BeforeAll START ===")
			GinkgoWriter.Printf("[BeforeAll] Importing from ZIP file: %s\n", exportedZipFile)
			suite.K2sCli().MustExec(ctx, "addons", "import", "-z", exportedZipFile)
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
						checkCmd := fmt.Sprintf("[ -d .%s/%s ]", i.ExportDirectoryName, pkg)
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", checkCmd)
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
						contains := slices.ContainsFunc(importedImages, func(imported string) bool {
							return strings.Contains(imported, img)
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
						checkCmd := fmt.Sprintf("[ -f %s ]", pkg.Destination)
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", checkCmd)
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
