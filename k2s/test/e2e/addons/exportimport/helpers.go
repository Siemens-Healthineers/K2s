// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Package exportimport provides shared helper functions for addon export/import tests.
package exportimport

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/addons"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"
)

// ExportedZipInfo contains information about an exported addon ZIP file.
type ExportedZipInfo struct {
	ZipPath       string
	ExtractedPath string
	AddonDir      string
}

// GetAddonByName returns the addon with the given name from the list of all addons.
func GetAddonByName(allAddons addons.Addons, addonName string) *addons.Addon {
	for i := range allAddons {
		if allAddons[i].Metadata.Name == addonName {
			return &allAddons[i]
		}
	}
	return nil
}

// GetImplementation returns the implementation with the given name from the addon.
func GetImplementation(addon *addons.Addon, implName string) *addons.Implementation {
	for i := range addon.Spec.Implementations {
		if addon.Spec.Implementations[i].Name == implName {
			return &addon.Spec.Implementations[i]
		}
	}
	return nil
}

// GetExpectedDirName returns the expected directory name for an addon implementation in the exported ZIP.
func GetExpectedDirName(addonName, implName string) string {
	if implName != addonName {
		return strings.ReplaceAll(addonName+"_"+implName, " ", "_")
	}
	return strings.ReplaceAll(addonName, " ", "_")
}

// ExportAddon exports a single addon (or implementation) to a ZIP file.
// Returns the path to the exported ZIP file.
func ExportAddon(ctx context.Context, suite *framework.K2sTestSuite, addonName string, implName string, outputDir string) string {
	GinkgoWriter.Printf("Exporting addon %s", addonName)
	if implName != "" && implName != addonName {
		GinkgoWriter.Printf(" implementation %s", implName)
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName+" "+implName, "-d", outputDir)
	} else {
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName, "-d", outputDir)
	}
	GinkgoWriter.Printf(" to %s\n", outputDir)

	// Find the exported ZIP file
	var pattern string
	if implName != "" && implName != addonName {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s-%s.zip", addonName, implName))
	} else {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s.zip", addonName))
	}

	files, err := filepath.Glob(pattern)
	Expect(err).ToNot(HaveOccurred())
	Expect(len(files)).To(Equal(1), "Should create exactly one versioned zip file for %s", addonName)

	return files[0]
}

// ExtractZip extracts the ZIP file to the given output directory.
// Returns the path to the extracted addons directory.
func ExtractZip(ctx context.Context, suite *framework.K2sTestSuite, zipPath string, outputDir string) string {
	suite.Cli("tar").MustExec(ctx, "-xf", zipPath, "-C", outputDir)

	extractedAddonsDir := filepath.Join(outputDir, "addons")
	_, err := os.Stat(extractedAddonsDir)
	Expect(os.IsNotExist(err)).To(BeFalse(), "addons directory should exist after extraction")

	return extractedAddonsDir
}

// VerifyExportedZipStructure verifies the structure of an exported addon ZIP.
func VerifyExportedZipStructure(extractedAddonsDir string, expectedDirName string) {
	// Check addon directory exists
	addonDir := filepath.Join(extractedAddonsDir, expectedDirName)
	_, err := os.Stat(addonDir)
	Expect(os.IsNotExist(err)).To(BeFalse(), "addon directory %s should exist", expectedDirName)

	// Check version.info exists
	versionInfoPath := filepath.Join(addonDir, "version.info")
	_, err = os.Stat(versionInfoPath)
	Expect(os.IsNotExist(err)).To(BeFalse(), "version.info should exist for addon %s", expectedDirName)
}

// VerifyExportedImages verifies that the expected images are exported as .tar files.
func VerifyExportedImages(suite *framework.K2sTestSuite, addonDir string, impl *addons.Implementation) {
	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).ToNot(HaveOccurred())

	exportedImages, err := GetFilesMatch(addonDir, "*.tar")
	Expect(err).ToNot(HaveOccurred())
	Expect(len(exportedImages)).To(Equal(len(images)),
		"Expected %d tar files to match %d images", len(exportedImages), len(images))
}

// VerifyExportedPackages verifies that all expected packages are exported.
func VerifyExportedPackages(addonDir string, impl *addons.Implementation) {
	// Check Linux curl packages
	for _, lp := range impl.OfflineUsage.LinuxResources.CurlPackages {
		pkgPath := filepath.Join(addonDir, "linuxpackages", filepath.Base(lp.Url))
		_, err := os.Stat(pkgPath)
		Expect(os.IsNotExist(err)).To(BeFalse(), "Linux curl package %s should exist", lp.Url)
	}

	// Check Debian packages
	for _, d := range impl.OfflineUsage.LinuxResources.DebPackages {
		pkgPath := filepath.Join(addonDir, "debianpackages", d)
		_, err := os.Stat(pkgPath)
		Expect(os.IsNotExist(err)).To(BeFalse(), "Debian package %s should exist", d)
	}

	// Check Windows curl packages
	for _, wp := range impl.OfflineUsage.WindowsResources.CurlPackages {
		pkgPath := filepath.Join(addonDir, "windowspackages", filepath.Base(wp.Url))
		_, err := os.Stat(pkgPath)
		Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist", wp.Url)
	}
}

// VerifyVersionInfo verifies that version.info contains CD-friendly information.
func VerifyVersionInfo(addonDir string, expectedDirName string) {
	versionInfoPath := filepath.Join(addonDir, "version.info")
	versionInfoBytes, err := os.ReadFile(versionInfoPath)
	Expect(err).To(BeNil(), "should be able to read version.info for addon %s", expectedDirName)

	versionInfo := string(versionInfoBytes)
	Expect(versionInfo).To(ContainSubstring("addonName"))
	Expect(versionInfo).To(ContainSubstring("implementationName"))
	Expect(versionInfo).To(ContainSubstring("k2sVersion"))
	Expect(versionInfo).To(ContainSubstring("exportDate"))
	Expect(versionInfo).To(ContainSubstring("exportType"))

	GinkgoWriter.Printf("Version info for %s: %s\n", expectedDirName, versionInfo[:min(200, len(versionInfo))])
}

// CleanAddonResources cleans up resources for a specific addon implementation.
func CleanAddonResources(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("Cleaning images for addon implementation:", impl.Name)
	suite.K2sCli().Exec(ctx, "image", "clean", "-o")

	GinkgoWriter.Println("Removing downloaded debian packages for implementation:", impl.Name)
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("sudo rm -rf .%s", impl.ExportDirectoryName))
}

// VerifyResourcesCleanedUp verifies that addon resources have been cleaned up.
func VerifyResourcesCleanedUp(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	// Verify debian packages are removed
	suite.K2sCli().ExpectedExitCode(1).Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s ]", impl.ExportDirectoryName))
}

// ImportAddon imports an addon from a ZIP file.
func ImportAddon(ctx context.Context, suite *framework.K2sTestSuite, zipPath string) {
	GinkgoWriter.Printf("Importing addon from %s\n", zipPath)
	suite.K2sCli().MustExec(ctx, "addons", "import", "-z", zipPath)
}

// VerifyImportedImages verifies that expected images are available after import.
func VerifyImportedImages(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation) {
	importedImages := k2sDsl.GetNonK8sImagesFromNodes(ctx)

	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).To(BeNil())

	for _, image := range images {
		contains := slices.ContainsFunc(importedImages, func(imported string) bool {
			return strings.Contains(imported, image)
		})
		Expect(contains).To(BeTrue(), "Image %s should be available after import", image)
	}
}

// VerifyImportedDebPackages verifies that expected debian packages are available after import.
func VerifyImportedDebPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string) {
	for _, pkg := range impl.OfflineUsage.LinuxResources.DebPackages {
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("[ -d .%s/%s ]", impl.ExportDirectoryName, pkg))
	}
}

// VerifyImportedLinuxCurlPackages verifies that expected linux curl packages are available after import.
func VerifyImportedLinuxCurlPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string) {
	for _, pkg := range impl.OfflineUsage.LinuxResources.CurlPackages {
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", fmt.Sprintf("[ -f %s ]", pkg.Destination))
	}
}

// VerifyImportedWindowsCurlPackages verifies that expected windows curl packages are available after import.
func VerifyImportedWindowsCurlPackages(suite *framework.K2sTestSuite, impl *addons.Implementation) {
	for _, p := range impl.OfflineUsage.WindowsResources.CurlPackages {
		_, err := os.Stat(filepath.Join(suite.RootDir(), p.Destination))
		Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist", p.Destination)
	}
}

// CleanupExportedFiles removes exported files and directories.
func CleanupExportedFiles(exportPath string, zipPath string) {
	extractedFolder := filepath.Join(exportPath, "addons")
	if _, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
		os.RemoveAll(extractedFolder)
	}
	if zipPath != "" {
		if _, err := os.Stat(zipPath); !os.IsNotExist(err) {
			os.Remove(zipPath)
		}
	}
}

// GetFilesMatch returns files matching the given pattern in the directory.
func GetFilesMatch(dir string, pattern string) ([]string, error) {
	var matches []string

	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}

		if d.IsDir() {
			return nil
		}

		matched, err := filepath.Match(pattern, filepath.Base(path))
		if err != nil {
			return err
		}

		if matched {
			matches = append(matches, path)
		}

		return nil
	})

	return matches, err
}

// IsEmptyDir checks if a directory is empty.
func IsEmptyDir(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return true
	}
	return len(entries) == 0
}

// FilterAddonByName filters addons to return only the one with the specified name.
func FilterAddonByName(allAddons addons.Addons, addonName string) addons.Addons {
	return lo.Filter(allAddons, func(a addons.Addon, _ int) bool {
		return a.Metadata.Name == addonName
	})
}
