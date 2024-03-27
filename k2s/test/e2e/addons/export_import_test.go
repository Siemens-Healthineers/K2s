// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
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

	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/test/framework"

	sos "github.com/siemens-healthineers/k2s/test/framework/os"

	"slices"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

const testClusterTimeout = time.Minute * 20

var (
	suite      *framework.K2sTestSuite
	linuxOnly  bool
	exportPath string
	allAddons  addons.Addons

	linuxTestContainers   []string
	windowsTestContainers []string
)

func TestExportImportAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Export and Import Addons Functional Tests", Label("functional", "acceptance", "internet-required", "setup-required", "invasive", "export-import", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))
	exportPath = filepath.Join(suite.RootDir(), "tmp")
	linuxOnly = suite.SetupInfo().SetupConfig.LinuxOnly
	allAddons = suite.AddonsAdditionalInfo().AllAddons()

	windowsTestContainers = []string{
		"shsk2s.azurecr.io/diskwriter:v1.0.0",
	}
	linuxTestContainers = []string{
		"shsk2s.azurecr.io/example.albums-golang-linux:v1.0.0",
		"docker.io/curlimages/curl:8.5.0",
	}
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
			extractedFolder := filepath.Join(exportPath, "addons")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}

			GinkgoWriter.Printf("Exporting all addons to %s", exportPath)
			if suite.Proxy() != "" {
				suite.K2sCli().Run(ctx, "addons", "export", "-d", exportPath, "-o", "-p", suite.Proxy())
			} else {
				suite.K2sCli().Run(ctx, "addons", "export", "-d", exportPath, "-o")
			}
		})

		AfterAll(func(ctx context.Context) {
			extractedFolder := filepath.Join(exportPath, "addons")
			if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
				os.RemoveAll(extractedFolder)
			}
		})

		It("addons are exported to zip file", func(ctx context.Context) {
			_, err := os.Stat(filepath.Join(exportPath, "addons.zip"))
			Expect(os.IsNotExist(err)).To(BeFalse())
		})

		It("contains a folder for every exported addon and each folder is not empty", func(ctx context.Context) {
			// addons.zip can be extracted
			suite.Cli().ExecOrFail(ctx, "tar", "-xf", filepath.Join(exportPath, "addons.zip"), "-C", exportPath)
			// check for extracted folder
			_, err := os.Stat(filepath.Join(exportPath, "addons"))
			Expect(os.IsNotExist(err)).To(BeFalse())

			// check for folder for each addon
			exportedAddonsDir, err := os.ReadDir(filepath.Join(exportPath, "addons"))
			Expect(err).To(BeNil())

			exportedAddonsDir = lo.Filter(exportedAddonsDir, func(x fs.DirEntry, index int) bool {
				return x.IsDir() && x.Name() != "hooks"
			})

			exportedAddons := lo.Map(exportedAddonsDir, func(x fs.DirEntry, index int) string {
				return x.Name()
			})

			for _, a := range allAddons {
				contains := slices.Contains(exportedAddons, filepath.Base(a.Directory))
				Expect(contains).To(BeTrue())
			}

			for _, e := range exportedAddons {
				addonsDir := filepath.Join(exportPath, "addons", e)
				Expect(sos.IsEmptyDir(addonsDir)).To(BeFalse())
			}
		})

		It("all resources have been exported", func(ctx context.Context) {
			for _, a := range allAddons {
				GinkgoWriter.Println("Addon:", a.Metadata.Name, ", Directory name:", filepath.Base(a.Directory))
				addonExportDir := filepath.Join(exportPath, "addons", filepath.Base(a.Directory))

				images, err := suite.AddonsAdditionalInfo().GetImagesForAddon(a)

				Expect(err).ToNot(HaveOccurred())

				GinkgoWriter.Println("check count of exported images is equal")
				exportedImages, err := sos.GetFilesMatch(addonExportDir, "*.tar")

				Expect(err).ToNot(HaveOccurred())
				GinkgoWriter.Printf("exportedImages: %d, images: %d", len(exportedImages), len(images))
				Expect(len(exportedImages)).To(Equal(len(images)))

				// check linux curl package count is equal
				GinkgoWriter.Println("check linux curl package count is equal")
				for _, lp := range a.Spec.OfflineUsage.LinuxResources.CurlPackages {
					_, err = os.Stat(filepath.Join(addonExportDir, "linuxpackages", filepath.Base(lp.Url)))
					Expect(os.IsNotExist(err)).To(BeFalse())
				}

				// check linux debian package count is equal
				GinkgoWriter.Println("check linux debian package count is equal")
				for _, d := range a.Spec.OfflineUsage.LinuxResources.DebPackages {
					_, err = os.Stat(filepath.Join(addonExportDir, "debianpackages", d))
					Expect(os.IsNotExist(err)).To(BeFalse())
				}

				// check windows curl package count is equal
				GinkgoWriter.Println("check windows curl package count is equal")
				for _, wp := range a.Spec.OfflineUsage.WindowsResources.CurlPackages {
					_, err = os.Stat(filepath.Join(addonExportDir, "windowspackages", filepath.Base(wp.Url)))
					Expect(os.IsNotExist(err)).To(BeFalse())
				}
			}
		})
	})

	Describe("clean up downloaded resources", func() {
		BeforeAll(func(ctx context.Context) {
			// clean up all images
			GinkgoWriter.Println("cleanup images")
			suite.K2sCli().Run(ctx, "image", "clean")

			// clean all downloaded
			GinkgoWriter.Println("remove all download debian packages")
			for _, a := range allAddons {
				suite.K2sCli().Run(ctx, "system", "ssh", "m", "--", "sudo rm -rf", fmt.Sprintf(".%s", filepath.Base(a.Directory)))
			}
		})

		It("no debian packages available before import", func(ctx context.Context) {
			for _, a := range allAddons {
				exists := suite.K2sCli().Run(ctx, "system", "ssh", "m", "--", fmt.Sprintf("[ -d .%s ] && echo .%s exists", filepath.Base(a.Directory), filepath.Base(a.Directory)))
				Expect(exists).To(BeEmpty())
			}
		})

		It("no images available before import", func(ctx context.Context) {
			images := suite.K2sCli().GetImages(ctx).GetContainerImages()
			Expect(len(images)).To(Equal(0))
		})
	})

	Describe("import all addons", func() {
		BeforeAll(func(ctx context.Context) {
			// clean up all images
			zipFile := filepath.Join(exportPath, "addons.zip")
			suite.K2sCli().Run(ctx, "addons", "import", "-z", zipFile)
		})

		AfterAll(func(ctx context.Context) {
			if _, err := os.Stat(exportPath); !os.IsNotExist(err) {
				os.RemoveAll(exportPath)
			}
		})

		It("debian packages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, v := range a.Spec.OfflineUsage.LinuxResources.DebPackages {
					exists := suite.K2sCli().Run(ctx, "system", "ssh", "m", "--", fmt.Sprintf("[ -d .%s/%s ] && echo .%s/%s exists", filepath.Base(a.Directory), v, filepath.Base(a.Directory), v))
					Expect(exists).ToNot(BeEmpty())
				}
			}
		})

		It("images available after import", func(ctx context.Context) {
			importedImages := suite.K2sCli().GetImages(ctx).GetContainerImages()
			for _, a := range allAddons {
				images, err := suite.AddonsAdditionalInfo().GetImagesForAddon(a)
				Expect(err).To(BeNil())

				for _, i := range images {
					contains := slices.ContainsFunc(importedImages, func(image string) bool {
						return strings.Contains(image, i)
					})
					Expect(contains).To(BeTrue())
				}
			}
		})

		It("linux curl packagages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, p := range a.Spec.OfflineUsage.LinuxResources.CurlPackages {
					exists := suite.K2sCli().Run(ctx, "system", "ssh", "m", "--", fmt.Sprintf("[ -f %s ] && echo %s exists", p.Destination, p.Destination))
					Expect(exists).ToNot(BeEmpty())
				}
			}
		})

		It("windows curl packagages available after import", func(ctx context.Context) {
			for _, a := range allAddons {
				for _, p := range a.Spec.OfflineUsage.WindowsResources.CurlPackages {
					_, err := os.Stat(filepath.Join(suite.RootDir(), p.Destination))
					Expect(os.IsNotExist(err)).To(BeFalse())
				}
			}
		})
	})

	Describe("download test containers", func() {
		It("test containers are available locally", func(ctx context.Context) {
			for _, image := range linuxTestContainers {
				suite.K2sCli().Run(ctx, "image", "pull", image)
				images := suite.K2sCli().GetImages(ctx).GetContainerImages()
				Expect(images).To(ContainElement(image))
			}

			for _, image := range windowsTestContainers {
				suite.K2sCli().Run(ctx, "image", "pull", image, "-w")
				images := suite.K2sCli().GetImages(ctx).GetContainerImages()
				Expect(images).To(ContainElement(image))
			}
		})
	})
})
