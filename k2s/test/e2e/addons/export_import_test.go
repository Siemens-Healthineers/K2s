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

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"
	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

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

	k2s *dsl.K2s
)

func TestExportImportAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Export and Import Addons Functional Tests", Label("functional", "acceptance", "internet-required", "setup-required", "invasive", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
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

	GinkgoWriter.Println("Using control-plane node IP address <", controlPlaneIpAddress, ">")

	k2s = dsl.NewK2s(suite)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
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
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					var expectedDirName string
					if i.Name != a.Metadata.Name {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name+"_"+i.Name, " ", "_")
					} else {
						expectedDirName = strings.ReplaceAll(a.Metadata.Name, " ", "_")
					}

					GinkgoWriter.Println("-> Addon:", a.Metadata.Name, ", Implementation:", i.Name, ", Expected Directory name:", expectedDirName)
					addonExportDir := filepath.Join(exportPath, "artifacts", expectedDirName)

					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).ToNot(HaveOccurred())

					// Check for image layers (consolidated into single tar files per platform)
					if len(images) > 0 {
						linuxImagesLayer := filepath.Join(addonExportDir, "images-linux.tar")
						windowsImagesLayer := filepath.Join(addonExportDir, "images-windows.tar")
						// At least one of the image layers should exist if there are images
						linuxExists := false
						windowsExists := false
						if _, err := os.Stat(linuxImagesLayer); err == nil {
							linuxExists = true
						}
						if _, err := os.Stat(windowsImagesLayer); err == nil {
							windowsExists = true
						}
						Expect(linuxExists || windowsExists).To(BeTrue(),
							"Expected at least one image layer (images-linux.tar or images-windows.tar) for addon %s with %d images", expectedDirName, len(images))
					}

					// Check OCI manifest exists
					_, err = os.Stat(filepath.Join(addonExportDir, "oci-manifest.json"))
					Expect(os.IsNotExist(err)).To(BeFalse(), "oci-manifest.json should exist for addon %s", expectedDirName)

					// Check for packages layer if offline_usage is defined
					hasLinuxPackages := len(i.OfflineUsage.LinuxResources.CurlPackages) > 0 || len(i.OfflineUsage.LinuxResources.DebPackages) > 0
					hasWindowsPackages := len(i.OfflineUsage.WindowsResources.CurlPackages) > 0
					if hasLinuxPackages || hasWindowsPackages {
						packagesLayer := filepath.Join(addonExportDir, "packages.tar.gz")
						_, err = os.Stat(packagesLayer)
						Expect(os.IsNotExist(err)).To(BeFalse(), "packages.tar.gz should exist for addon %s with offline packages", expectedDirName)
					}
				}
			}
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
			GinkgoWriter.Println("cleanup images")
			suite.K2sCli().Exec(ctx, "image", "clean", "-o")

			GinkgoWriter.Println("remove all download debian packages")
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("sudo rm -rf .%s", i.ExportDirectoryName))
				}
			}
		})

		It("no debian packages available before import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s ]", i.ExportDirectoryName))
				}
			}
		})

		It("no images available before import", func(ctx context.Context) {
			images := k2s.GetNonK8sImagesFromNodes(ctx)

			Expect(images).To(BeEmpty())
		})
	})

	Describe("import all addons", func() {
		BeforeAll(func(ctx context.Context) {
			suite.K2sCli().MustExec(ctx, "addons", "import", "-z", exportedOciFile)
		}, NodeTimeout(time.Minute*30))

		AfterAll(func(ctx context.Context) {
			if _, err := os.Stat(exportPath); !os.IsNotExist(err) {
				os.RemoveAll(exportPath)
			}
		})

		It("debian packages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					for _, pkg := range i.OfflineUsage.LinuxResources.DebPackages {
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s/%s ]", i.ExportDirectoryName, pkg))
					}
				}
			}
		})

		It("images available after import", func(ctx context.Context) {
			importedImages := k2s.GetNonK8sImagesFromNodes(ctx)
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(i)
					Expect(err).To(BeNil())

					for _, i := range images {
						contains := slices.ContainsFunc(importedImages, func(image string) bool {
							return strings.Contains(image, i)
						})
						Expect(contains).To(BeTrue())
					}
				}
			}
		})

		It("linux curl packages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					for _, pkg := range i.OfflineUsage.LinuxResources.CurlPackages {
						suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIpAddress, "-u", "remote", "-c", fmt.Sprintf("[ -f %s ]", pkg.Destination))
					}
				}
			}
		})

		It("windows curl packages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, i := range a.Spec.Implementations {
					for _, p := range i.OfflineUsage.WindowsResources.CurlPackages {
						_, err := os.Stat(filepath.Join(suite.RootDir(), p.Destination))
						Expect(os.IsNotExist(err)).To(BeFalse())
					}
				}
			}
		})

		It("OCI layer files are excluded during import but addon content is imported", func(ctx context.Context) {
			addonsDirs, err := os.ReadDir(filepath.Join(suite.RootDir(), "addons"))
			Expect(err).To(BeNil())

			for _, addonDir := range addonsDirs {
				if !addonDir.IsDir() {
					continue
				}

				addonPath := filepath.Join(suite.RootDir(), "addons", addonDir.Name())

				err := filepath.WalkDir(addonPath, func(path string, d os.DirEntry, err error) error {
					if err != nil {
						return err
					}

					if !d.IsDir() {
						// Check that no OCI layer artifacts remain after import
						if strings.HasSuffix(d.Name(), ".tar") && !strings.Contains(path, "manifests") {
							Fail(fmt.Sprintf("Found .tar file in addon directory: %s", path))
						}
						if strings.HasSuffix(d.Name(), ".tar.gz") {
							Fail(fmt.Sprintf("Found .tar.gz layer file in addon directory: %s", path))
						}
						if d.Name() == "oci-manifest.json" {
							Fail(fmt.Sprintf("Found oci-manifest.json in addon directory: %s", path))
						}
					}

					return nil
				})

				Expect(err).To(BeNil())

				manifestPath := filepath.Join(addonPath, "addon.manifest.yaml")
				if _, err := os.Stat(manifestPath); err == nil {
					GinkgoWriter.Printf("Verified manifest exists for addon: %s", addonDir.Name())
				}
			}

			GinkgoWriter.Println("Verified: No OCI layer files found in addon directories after import")
		})

		It("OCI artifacts are processed and cleaned up during import", func(ctx context.Context) {
			addonsDirs, err := os.ReadDir(filepath.Join(suite.RootDir(), "addons"))
			Expect(err).To(BeNil())

			for _, addonDir := range addonsDirs {
				if !addonDir.IsDir() {
					continue
				}

				addonPath := filepath.Join(suite.RootDir(), "addons", addonDir.Name())

				err := filepath.WalkDir(addonPath, func(path string, d os.DirEntry, err error) error {
					if err != nil {
						return err
					}

					if !d.IsDir() {
						// Legacy version.info should not exist
						if d.Name() == "version.info" {
							Fail(fmt.Sprintf("Found version.info file in final addon directory: %s", path))
						}
						// OCI manifest should not exist in final addon directory
						if d.Name() == "oci-manifest.json" {
							Fail(fmt.Sprintf("Found oci-manifest.json in final addon directory: %s", path))
						}
					}

					return nil
				})

				Expect(err).To(BeNil())
			}

			GinkgoWriter.Println("Verified: No OCI artifacts or version.info files found in final addon directories after import")
		})

		It("manifest merging preserves multiple implementations", func(ctx context.Context) {
			ingressManifestPath := filepath.Join(suite.RootDir(), "addons", "ingress", "addon.manifest.yaml")
			if _, err := os.Stat(ingressManifestPath); err == nil {
				manifestContent, err := os.ReadFile(ingressManifestPath)
				Expect(err).To(BeNil())
				manifestStr := string(manifestContent)

				Expect(manifestStr).To(ContainSubstring("nginx"), "Ingress manifest should contain nginx implementation")
				Expect(manifestStr).To(ContainSubstring("traefik"), "Ingress manifest should contain traefik implementation")

				Expect(manifestStr).To(ContainSubstring("SPDX-FileCopyrightText"), "Manifest should preserve SPDX header")
				Expect(manifestStr).To(ContainSubstring("SPDX-License-Identifier"), "Manifest should preserve license identifier")

				GinkgoWriter.Println("Verified: Ingress manifest contains both nginx and traefik implementations")
			} else {
				GinkgoWriter.Println("Ingress manifest not found - skipping manifest merging test")
			}
		})
	})

	Describe("export single implementation addon", func() {
		var singleImplOciFile string

		BeforeAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "artifacts")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}

			GinkgoWriter.Printf("Exporting single implementation addon to %s", exportPath)
			suite.K2sCli().MustExec(ctx, "addons", "export", "ingress nginx", "-d", exportPath)
		})

		AfterAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "artifacts")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}
			if singleImplOciFile != "" && strings.HasSuffix(singleImplOciFile, ".oci.tar") {
				os.Remove(singleImplOciFile)
			}
		})

		It("single implementation addon is exported with filtered manifest in OCI format", func(ctx context.Context) {
			files, err := filepath.Glob(filepath.Join(exportPath, "K2s-*-addons-ingress-nginx.oci.tar"))
			Expect(err).To(BeNil())
			Expect(len(files)).To(Equal(1), "Should create exactly one versioned OCI tar file for single implementation")

			singleImplOciFile = files[0]
			_, err = os.Stat(singleImplOciFile)
			Expect(os.IsNotExist(err)).To(BeFalse())

			suite.Cli("tar").MustExec(ctx, "-xf", singleImplOciFile, "-C", exportPath)

			ingressNginxDir := filepath.Join(exportPath, "artifacts", "ingress_nginx")
			_, err = os.Stat(ingressNginxDir)
			Expect(os.IsNotExist(err)).To(BeFalse(), "ingress_nginx directory should exist")

			// Check for OCI manifest
			ociManifestPath := filepath.Join(ingressNginxDir, "oci-manifest.json")
			_, err = os.Stat(ociManifestPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "oci-manifest.json should exist")

			// Check for scripts layer
			scriptsLayerPath := filepath.Join(ingressNginxDir, "scripts.tar.gz")
			_, err = os.Stat(scriptsLayerPath)
			Expect(os.IsNotExist(err)).To(BeFalse(), "scripts.tar.gz should exist")

			manifestPath := filepath.Join(ingressNginxDir, "addon.manifest.yaml")
			if _, err := os.Stat(manifestPath); err == nil {
				manifestContent, err := os.ReadFile(manifestPath)
				Expect(err).To(BeNil())
				manifestStr := string(manifestContent)

				Expect(manifestStr).To(ContainSubstring("nginx"))
				Expect(manifestStr).ToNot(ContainSubstring("traefik"))

				GinkgoWriter.Println("Single implementation manifest verified - contains only nginx implementation")
			}
		})
	})

	Describe("download test containers", func() {
		It("test containers are available locally", func(ctx context.Context) {
			for _, image := range linuxTestContainers {
				suite.K2sCli().MustExec(ctx, "image", "pull", image)
			}

			for _, image := range windowsTestContainers {
				suite.K2sCli().MustExec(ctx, "image", "pull", image, "-w")
			}

			images := k2s.GetNonK8sImagesFromNodes(ctx)

			Expect(images).To(SatisfyAll(
				ContainElements(linuxTestContainers),
				ContainElements(windowsTestContainers),
			))
		})
	})
})
