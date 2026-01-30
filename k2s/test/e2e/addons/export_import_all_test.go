// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package addons

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
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

		It("contains proper OCI structure with all addons referenced in index.json", func(ctx context.Context) {
			suite.Cli("tar").MustExec(ctx, "-xf", exportedOciFile, "-C", exportPath)

			artifactsPath := filepath.Join(exportPath, "artifacts")
			_, err := os.Stat(artifactsPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "artifacts directory should exist")

			// Verify OCI layout file
			ociLayoutPath := filepath.Join(artifactsPath, "oci-layout")
			_, err = os.Stat(ociLayoutPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "oci-layout file should exist")

			// Verify blobs directory
			blobsPath := filepath.Join(artifactsPath, "blobs", "sha256")
			_, err = os.Stat(blobsPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "blobs/sha256 directory should exist")

			// Verify addons.json metadata file
			_, err = os.Stat(filepath.Join(artifactsPath, "addons.json"))
			Expect(os.IsNotExist(err)).To(BeFalse(), "addons.json metadata file should exist")

			// Read and parse index.json
			indexPath := filepath.Join(artifactsPath, "index.json")
			_, err = os.Stat(indexPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "index.json OCI index file should exist")

			indexData, err := os.ReadFile(indexPath)
			Expect(err).To(BeNil(), "should be able to read index.json")

			var ociIndex struct {
				SchemaVersion int    `json:"schemaVersion"`
				MediaType     string `json:"mediaType"`
				Manifests     []struct {
					MediaType    string `json:"mediaType"`
					Size         int64  `json:"size"`
					Digest       string `json:"digest"`
					ArtifactType string `json:"artifactType"`
					Annotations  struct {
						AddonName           string `json:"vnd.k2s.addon.name"`
						AddonImplementation string `json:"vnd.k2s.addon.implementation"`
						AddonVersion        string `json:"vnd.k2s.addon.version"`
					} `json:"annotations"`
				} `json:"manifests"`
			}
			err = json.Unmarshal(indexData, &ociIndex)
			Expect(err).To(BeNil(), "should be able to parse index.json")

			Expect(ociIndex.SchemaVersion).To(Equal(2), "OCI index schema version should be 2")
			Expect(ociIndex.MediaType).To(Equal("application/vnd.oci.image.index.v1+json"), "OCI index media type should be correct")

			GinkgoWriter.Printf("Found %d addon manifests in OCI index\n", len(ociIndex.Manifests))

			// Verify each addon is present in index
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					var expectedName string
					if i.Name != a.Metadata.Name {
						expectedName = strings.ReplaceAll(a.Metadata.Name+"_"+i.Name, " ", "_")
					} else {
						expectedName = strings.ReplaceAll(a.Metadata.Name, " ", "_")
					}

					GinkgoWriter.Printf("Verifying addon: %s (implementation: %s) -> expected name: %s\n",
						a.Metadata.Name, i.Name, expectedName)

					found := false
					for _, manifest := range ociIndex.Manifests {
						if manifest.Annotations.AddonName == expectedName {
							found = true
							GinkgoWriter.Printf("  Found in index.json: digest=%s, size=%d\n",
								manifest.Digest, manifest.Size)

							// Verify the manifest blob exists
							digestHash := strings.TrimPrefix(manifest.Digest, "sha256:")
							blobPath := filepath.Join(blobsPath, digestHash)
							_, err := os.Stat(blobPath)
							Expect(os.IsNotExist(err)).To(BeFalse(),
								"manifest blob should exist at %s for addon %s", blobPath, expectedName)

							Expect(manifest.ArtifactType).To(Equal("application/vnd.k2s.addon.v1"),
								"artifact type should be correct for addon %s", expectedName)
							break
						}
					}
					Expect(found).To(BeTrue(), "addon %s should be referenced in index.json", expectedName)
				}
			}
		})

		It("all resources have been exported as OCI layers in blobs", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: all resources have been exported as OCI layers in blobs")
			GinkgoWriter.Printf("[Test] Checking %d addons\n", len(allAddons))

			// Read index.json to get all addon manifests
			indexPath := filepath.Join(exportPath, "artifacts", "index.json")
			indexData, err := os.ReadFile(indexPath)
			Expect(err).To(BeNil(), "should be able to read index.json")

			var ociIndex struct {
				Manifests []struct {
					Digest      string `json:"digest"`
					Annotations struct {
						AddonName           string `json:"vnd.k2s.addon.name"`
						AddonImplementation string `json:"vnd.k2s.addon.implementation"`
					} `json:"annotations"`
				} `json:"manifests"`
			}
			err = json.Unmarshal(indexData, &ociIndex)
			Expect(err).To(BeNil(), "should be able to parse index.json")

			blobsPath := filepath.Join(exportPath, "artifacts", "blobs", "sha256")

			for addonIdx, a := range allAddons {
				for implIdx, i := range a.Spec.Implementations {
					var expectedName string
					if i.Name != a.Metadata.Name {
						expectedName = strings.ReplaceAll(a.Metadata.Name+"_"+i.Name, " ", "_")
					} else {
						expectedName = strings.ReplaceAll(a.Metadata.Name, " ", "_")
					}

					GinkgoWriter.Printf("[Test] [%d.%d] Addon: %s, Implementation: %s, Expected Name: %s\n",
						addonIdx, implIdx, a.Metadata.Name, i.Name, expectedName)

					// Find the manifest for this addon in the index
					var manifestDigest string
					for _, m := range ociIndex.Manifests {
						if m.Annotations.AddonName == expectedName {
							manifestDigest = m.Digest
							break
						}
					}
					Expect(manifestDigest).NotTo(BeEmpty(), "should find manifest for addon %s in index", expectedName)

					// Read the OCI manifest from blobs
					digestHash := strings.TrimPrefix(manifestDigest, "sha256:")
					manifestBlobPath := filepath.Join(blobsPath, digestHash)
					manifestData, err := os.ReadFile(manifestBlobPath)
					Expect(err).To(BeNil(), "should be able to read manifest blob for addon %s", expectedName)

					var ociManifest struct {
						SchemaVersion int    `json:"schemaVersion"`
						MediaType     string `json:"mediaType"`
						Config        struct {
							Digest string `json:"digest"`
						} `json:"config"`
						Layers []struct {
							MediaType string `json:"mediaType"`
							Digest    string `json:"digest"`
							Size      int64  `json:"size"`
						} `json:"layers"`
					}
					err = json.Unmarshal(manifestData, &ociManifest)
					Expect(err).To(BeNil(), "should be able to parse manifest for addon %s", expectedName)

					GinkgoWriter.Printf("[Test]   Manifest has %d layers\n", len(ociManifest.Layers))

					// Verify config blob exists
					configHash := strings.TrimPrefix(ociManifest.Config.Digest, "sha256:")
					configBlobPath := filepath.Join(blobsPath, configHash)
					_, err = os.Stat(configBlobPath)
					Expect(os.IsNotExist(err)).To(BeFalse(), "config blob should exist for addon %s", expectedName)
					GinkgoWriter.Printf("[Test]   Config blob exists: %s\n", ociManifest.Config.Digest)

					// Verify all layer blobs exist
					for layerIdx, layer := range ociManifest.Layers {
						layerHash := strings.TrimPrefix(layer.Digest, "sha256:")
						layerBlobPath := filepath.Join(blobsPath, layerHash)
						_, err = os.Stat(layerBlobPath)
						Expect(os.IsNotExist(err)).To(BeFalse(),
							"layer %d blob should exist for addon %s (digest: %s)",
							layerIdx, expectedName, layer.Digest)
						GinkgoWriter.Printf("[Test]   Layer %d exists: %s (size: %d, type: %s)\n",
							layerIdx, layer.Digest, layer.Size, layer.MediaType)
					}

					// Verify expected layer types based on addon configuration
					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).ToNot(HaveOccurred())

					if len(images) > 0 {
						// Should have at least one image layer
						hasImageLayer := false
						for _, layer := range ociManifest.Layers {
							if strings.Contains(layer.MediaType, "vnd.oci.image.layer") {
								hasImageLayer = true
								break
							}
						}
						Expect(hasImageLayer).To(BeTrue(),
							"addon %s with %d images should have image layer", expectedName, len(images))
						GinkgoWriter.Printf("[Test]   Image layers verified (%d images expected)\n", len(images))
					}

					// Verify packages layer if offline_usage is defined
					hasLinuxPackages := len(i.OfflineUsage.LinuxResources.CurlPackages) > 0 || len(i.OfflineUsage.LinuxResources.DebPackages) > 0
					hasWindowsPackages := len(i.OfflineUsage.WindowsResources.CurlPackages) > 0
					if hasLinuxPackages || hasWindowsPackages {
						hasPackageLayer := false
						for _, layer := range ociManifest.Layers {
							if strings.Contains(layer.MediaType, "vnd.k2s.addon.packages") {
								hasPackageLayer = true
								break
							}
						}
						Expect(hasPackageLayer).To(BeTrue(),
							"addon %s with offline packages should have packages layer", expectedName)
						GinkgoWriter.Printf("[Test]   Packages layer verified\n")
					}

					GinkgoWriter.Printf("[Test]   OK: All OCI layers verified in blobs for %s\n", expectedName)
				}
			}
			GinkgoWriter.Println("[Test] All addons OCI layers verified successfully in blobs")
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

		It("OCI manifests in blobs contain proper structure", func(ctx context.Context) {
			GinkgoWriter.Println(">>> TEST: OCI manifests in blobs contain proper structure")

			// Read index.json to get all addon manifests
			indexPath := filepath.Join(exportPath, "artifacts", "index.json")
			indexData, err := os.ReadFile(indexPath)
			Expect(err).To(BeNil(), "should be able to read index.json")

			var ociIndex struct {
				Manifests []struct {
					Digest      string `json:"digest"`
					Annotations struct {
						AddonName string `json:"vnd.k2s.addon.name"`
					} `json:"annotations"`
				} `json:"manifests"`
			}
			err = json.Unmarshal(indexData, &ociIndex)
			Expect(err).To(BeNil(), "should be able to parse index.json")

			blobsPath := filepath.Join(exportPath, "artifacts", "blobs", "sha256")
			GinkgoWriter.Printf("[Test] Checking %d manifests in blobs\n", len(ociIndex.Manifests))

			for idx, manifest := range ociIndex.Manifests {
				digestHash := strings.TrimPrefix(manifest.Digest, "sha256:")
				manifestBlobPath := filepath.Join(blobsPath, digestHash)
				manifestData, err := os.ReadFile(manifestBlobPath)
				Expect(err).To(BeNil(), "should be able to read manifest blob for addon %s", manifest.Annotations.AddonName)

				manifestStr := string(manifestData)
				Expect(manifestStr).To(ContainSubstring("schemaVersion"), "manifest should have schemaVersion")
				Expect(manifestStr).To(ContainSubstring("mediaType"), "manifest should have mediaType")
				Expect(manifestStr).To(ContainSubstring("layers"), "manifest should have layers")
				Expect(manifestStr).To(ContainSubstring("config"), "manifest should have config")

				GinkgoWriter.Printf("[Test] [%d] OCI manifest verified for %s (digest: %s)\n",
					idx, manifest.Annotations.AddonName, manifest.Digest)
			}

			GinkgoWriter.Println("[Test] All OCI manifests in blobs verified")
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
