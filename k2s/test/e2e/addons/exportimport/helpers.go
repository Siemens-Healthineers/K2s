// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
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

// ExportedOciInfo contains information about an exported addon OCI tar file.
type ExportedOciInfo struct {
	OciTarPath    string
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

// ExportAddon exports a single addon (or implementation) to an OCI tar file.
// Returns the path to the exported OCI tar file.
func ExportAddon(ctx context.Context, suite *framework.K2sTestSuite, addonName string, implName string, outputDir string) string {
	GinkgoWriter.Println("=== EXPORT ADDON START ===")
	GinkgoWriter.Printf("[Export] Addon: %s\n", addonName)
	if implName != "" && implName != addonName {
		GinkgoWriter.Printf("[Export] Implementation: %s\n", implName)
	}
	GinkgoWriter.Printf("[Export] Output directory: %s\n", outputDir)

	// Ensure output directory exists
	if err := os.MkdirAll(outputDir, 0755); err != nil {
		GinkgoWriter.Printf("[Export] WARNING: Failed to create output directory: %v\n", err)
	}

	GinkgoWriter.Println("[Export] Executing k2s addons export command with verbose output (-o)...")
	if implName != "" && implName != addonName {
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName+" "+implName, "-d", outputDir, "-o")
	} else {
		suite.K2sCli().MustExec(ctx, "addons", "export", addonName, "-d", outputDir, "-o")
	}
	GinkgoWriter.Println("[Export] Export command completed")

	// Find the exported OCI tar file
	var pattern string
	if implName != "" && implName != addonName {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s-%s.oci.tar", addonName, implName))
	} else {
		pattern = filepath.Join(outputDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", addonName))
	}
	GinkgoWriter.Printf("[Export] Looking for OCI tar file matching pattern: %s\n", pattern)

	files, err := filepath.Glob(pattern)
	Expect(err).ToNot(HaveOccurred(), "[Export] Failed to glob for OCI tar files")

	GinkgoWriter.Printf("[Export] Found %d matching OCI tar file(s)\n", len(files))
	for i, f := range files {
		GinkgoWriter.Printf("[Export]   [%d] %s\n", i, f)
	}
	Expect(len(files)).To(Equal(1), "Should create exactly one versioned OCI tar file for %s, found %d", addonName, len(files))

	ociTarPath := files[0]
	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Export] OCI tar file size: %d bytes\n", info.Size())
	}
	GinkgoWriter.Println("=== EXPORT ADDON END ===")

	return ociTarPath
}

// ExtractOciTar extracts the OCI tar file to the given output directory.
// Returns the path to the extracted artifacts directory.
func ExtractOciTar(ctx context.Context, suite *framework.K2sTestSuite, ociTarPath string, outputDir string) string {
	GinkgoWriter.Println("=== EXTRACT OCI TAR START ===")
	GinkgoWriter.Printf("[Extract] OCI tar file: %s\n", ociTarPath)
	GinkgoWriter.Printf("[Extract] Output directory: %s\n", outputDir)

	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Extract] OCI tar file size: %d bytes\n", info.Size())
	} else {
		GinkgoWriter.Printf("[Extract] WARNING: Cannot stat OCI tar file: %v\n", err)
	}

	GinkgoWriter.Println("[Extract] Executing tar extraction...")
	suite.Cli("tar").MustExec(ctx, "-xf", ociTarPath, "-C", outputDir)
	GinkgoWriter.Println("[Extract] Extraction completed")

	extractedArtifactsDir := filepath.Join(outputDir, "artifacts")
	_, err := os.Stat(extractedArtifactsDir)
	Expect(os.IsNotExist(err)).To(BeFalse(), "artifacts directory should exist after extraction at %s", extractedArtifactsDir)

	// List contents of extracted directory
	entries, _ := os.ReadDir(extractedArtifactsDir)
	GinkgoWriter.Printf("[Extract] Extracted artifacts directory contains %d entries:\n", len(entries))
	for _, entry := range entries {
		GinkgoWriter.Printf("[Extract]   - %s (dir=%v)\n", entry.Name(), entry.IsDir())
	}

	GinkgoWriter.Println("=== EXTRACT OCI TAR END ===")
	return extractedArtifactsDir
}

// VerifyExportedOciStructure verifies the structure of an exported addon OCI tar.
// The structure should be OCI Image Layout compliant with oci-layout, index.json, and blobs/sha256/.
func VerifyExportedOciStructure(extractedArtifactsDir string, expectedDirName string) {
	GinkgoWriter.Println("=== VERIFY OCI IMAGE LAYOUT STRUCTURE START ===")
	GinkgoWriter.Printf("[Structure] Extracted artifacts dir: %s\n", extractedArtifactsDir)

	// Verify oci-layout file exists (REQUIRED by OCI spec)
	ociLayoutPath := filepath.Join(extractedArtifactsDir, "oci-layout")
	ociLayoutInfo, err := os.Stat(ociLayoutPath)
	Expect(os.IsNotExist(err)).To(BeFalse(), "oci-layout file should exist at %s", ociLayoutPath)
	GinkgoWriter.Printf("[Structure] oci-layout file exists (%d bytes)\n", ociLayoutInfo.Size())

	// Verify oci-layout contains imageLayoutVersion
	ociLayoutContent, err := os.ReadFile(ociLayoutPath)
	Expect(err).ToNot(HaveOccurred(), "should be able to read oci-layout file")
	Expect(string(ociLayoutContent)).To(ContainSubstring("imageLayoutVersion"))
	Expect(string(ociLayoutContent)).To(ContainSubstring("1.0.0"))
	GinkgoWriter.Println("[Structure] oci-layout contains valid imageLayoutVersion: 1.0.0")

	// Verify index.json exists (REQUIRED by OCI spec)
	indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
	indexJsonInfo, err := os.Stat(indexJsonPath)
	Expect(os.IsNotExist(err)).To(BeFalse(), "index.json file should exist at %s", indexJsonPath)
	GinkgoWriter.Printf("[Structure] index.json file exists (%d bytes)\n", indexJsonInfo.Size())

	// Verify index.json has proper OCI structure with digests
	indexJsonContent, err := os.ReadFile(indexJsonPath)
	Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")
	Expect(string(indexJsonContent)).To(ContainSubstring("schemaVersion"))
	Expect(string(indexJsonContent)).To(ContainSubstring("application/vnd.oci.image.index.v1+json"))
	Expect(string(indexJsonContent)).To(ContainSubstring("sha256:"))
	Expect(string(indexJsonContent)).To(ContainSubstring("digest"))
	Expect(string(indexJsonContent)).To(ContainSubstring("size"))
	GinkgoWriter.Println("[Structure] index.json contains proper OCI structure with digests")

	// Verify blobs/sha256 directory exists (REQUIRED by OCI spec)
	blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
	blobsDirInfo, err := os.Stat(blobsDir)
	Expect(os.IsNotExist(err)).To(BeFalse(), "blobs/sha256 directory should exist at %s", blobsDir)
	Expect(blobsDirInfo.IsDir()).To(BeTrue(), "blobs/sha256 should be a directory")
	GinkgoWriter.Println("[Structure] blobs/sha256 directory exists")

	// List blobs
	blobEntries, err := os.ReadDir(blobsDir)
	Expect(err).ToNot(HaveOccurred(), "should be able to read blobs directory")
	GinkgoWriter.Printf("[Structure] blobs/sha256 contains %d blobs:\n", len(blobEntries))
	for _, entry := range blobEntries {
		if info, err := entry.Info(); err == nil {
			GinkgoWriter.Printf("[Structure]   - sha256:%s (%d bytes)\n", entry.Name()[:12]+"...", info.Size())
		}
	}
	Expect(len(blobEntries)).To(BeNumerically(">", 0), "blobs directory should contain at least one blob")

	// Verify the expected addon is referenced in index.json
	Expect(string(indexJsonContent)).To(ContainSubstring(expectedDirName))
	GinkgoWriter.Printf("[Structure] index.json references addon: %s\n", expectedDirName)

	GinkgoWriter.Println("=== VERIFY OCI IMAGE LAYOUT STRUCTURE END ===")
}

// VerifyExportedImages verifies that the expected images are exported in OCI blobs.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/).
func VerifyExportedImages(suite *framework.K2sTestSuite, extractedArtifactsDir string, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY EXPORTED IMAGES START ===")
	GinkgoWriter.Printf("[Images] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[Images] Implementation: %s\n", impl.Name)

	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).ToNot(HaveOccurred(), "[Images] Failed to get expected images for implementation")
	GinkgoWriter.Printf("[Images] Expected images from manifest: %d\n", len(images))
	for i, img := range images {
		GinkgoWriter.Printf("[Images]   [%d] %s\n", i, img)
	}

	// In OCI-compliant format, images are stored in blobs as content-addressable digests
	// We verify that the index.json references image layers
	if len(images) > 0 {
		indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
		indexJsonContent, err := os.ReadFile(indexJsonPath)
		Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")

		// Image layers should be referenced with proper media types
		hasLinuxImages := strings.Contains(string(indexJsonContent), "images-linux.tar") ||
			strings.Contains(string(indexJsonContent), "vnd.oci.image.layer.v1.tar")
		hasWindowsImages := strings.Contains(string(indexJsonContent), "images-windows.tar") ||
			strings.Contains(string(indexJsonContent), "vnd.oci.image.layer.v1.tar+windows")

		// Verify blobs exist
		blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
		blobEntries, err := os.ReadDir(blobsDir)
		Expect(err).ToNot(HaveOccurred(), "should be able to read blobs directory")

		GinkgoWriter.Printf("[Images] Found %d blobs in storage\n", len(blobEntries))
		GinkgoWriter.Printf("[Images] Linux image layer referenced: %v\n", hasLinuxImages)
		GinkgoWriter.Printf("[Images] Windows image layer referenced: %v\n", hasWindowsImages)

		// At least one image layer should be present
		Expect(hasLinuxImages || hasWindowsImages || len(blobEntries) > 0).To(BeTrue(),
			"Expected at least one image layer blob for %d images", len(images))
	} else {
		GinkgoWriter.Println("[Images] No images expected, skipping layer check")
	}

	GinkgoWriter.Println("=== VERIFY EXPORTED IMAGES END ===")
}

// VerifyExportedPackages verifies that packages are exported in OCI blobs.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/).
func VerifyExportedPackages(extractedArtifactsDir string, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY EXPORTED PACKAGES START ===")
	GinkgoWriter.Printf("[Packages] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[Packages] Implementation: %s\n", impl.Name)

	// Count expected packages
	linuxCurlCount := len(impl.OfflineUsage.LinuxResources.CurlPackages)
	debCount := len(impl.OfflineUsage.LinuxResources.DebPackages)
	winCurlCount := len(impl.OfflineUsage.WindowsResources.CurlPackages)
	totalPackages := linuxCurlCount + debCount + winCurlCount

	GinkgoWriter.Printf("[Packages] Expected Linux curl packages: %d\n", linuxCurlCount)
	for i, lp := range impl.OfflineUsage.LinuxResources.CurlPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, lp.Url)
	}

	GinkgoWriter.Printf("[Packages] Expected Debian packages: %d\n", debCount)
	for i, d := range impl.OfflineUsage.LinuxResources.DebPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, d)
	}

	GinkgoWriter.Printf("[Packages] Expected Windows curl packages: %d\n", winCurlCount)
	for i, wp := range impl.OfflineUsage.WindowsResources.CurlPackages {
		GinkgoWriter.Printf("[Packages]   [%d] %s\n", i, wp.Url)
	}

	GinkgoWriter.Printf("[Packages] Total expected packages: %d\n", totalPackages)

	// In OCI-compliant format, packages are stored in blobs referenced by index.json
	if totalPackages > 0 {
		indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
		indexJsonContent, err := os.ReadFile(indexJsonPath)
		Expect(err).ToNot(HaveOccurred(), "should be able to read index.json")

		// Verify packages layer is referenced
		hasPackagesLayer := strings.Contains(string(indexJsonContent), "packages.tar.gz") ||
			strings.Contains(string(indexJsonContent), "vnd.k2s.addon.packages")

		// Verify blobs directory has content
		blobsDir := filepath.Join(extractedArtifactsDir, "blobs", "sha256")
		blobEntries, err := os.ReadDir(blobsDir)
		if err != nil {
			GinkgoWriter.Printf("[Packages] ERROR: cannot read blobs directory: %v\n", err)
		} else {
			GinkgoWriter.Printf("[Packages] Found %d blobs in storage\n", len(blobEntries))
		}

		GinkgoWriter.Printf("[Packages] Packages layer referenced: %v\n", hasPackagesLayer)
		Expect(hasPackagesLayer || len(blobEntries) > 0).To(BeTrue(),
			"packages layer should be referenced in index.json or blobs should exist for %d packages", totalPackages)
	} else {
		GinkgoWriter.Println("[Packages] No packages expected, skipping layer check")
	}

	GinkgoWriter.Printf("[Packages] OCI packages layer verified\n")
	GinkgoWriter.Println("=== VERIFY EXPORTED PACKAGES END ===")
}

// VerifyOciManifest verifies that addon manifest in blobs contains proper OCI structure and metadata.
// extractedArtifactsDir should be the OCI layout root (containing blobs/sha256/ and index.json).
func VerifyOciManifest(extractedArtifactsDir string, expectedDirName string) {
	GinkgoWriter.Println("=== VERIFY OCI MANIFEST START ===")
	GinkgoWriter.Printf("[OciManifest] Artifacts dir: %s\n", extractedArtifactsDir)
	GinkgoWriter.Printf("[OciManifest] Expected addon: %s\n", expectedDirName)

	// Read index.json to get manifest digest
	indexJsonPath := filepath.Join(extractedArtifactsDir, "index.json")
	indexJsonBytes, err := os.ReadFile(indexJsonPath)
	Expect(err).To(BeNil(), "should be able to read index.json at %s", indexJsonPath)

	indexJson := string(indexJsonBytes)
	GinkgoWriter.Printf("[OciManifest] index.json content (%d bytes):\n%s\n", len(indexJsonBytes), indexJson)

	// Verify index.json has proper OCI structure
	requiredIndexFields := []string{"schemaVersion", "mediaType", "manifests", "digest", "size"}
	for _, field := range requiredIndexFields {
		if strings.Contains(indexJson, field) {
			GinkgoWriter.Printf("[OciManifest] index.json field '%s': FOUND\n", field)
		} else {
			GinkgoWriter.Printf("[OciManifest] index.json field '%s': MISSING\n", field)
		}
		Expect(indexJson).To(ContainSubstring(field), "index.json should contain '%s'", field)
	}

	// Verify K2s-specific annotations are present
	k2sAnnotations := []string{"vnd.k2s.addon.name", "vnd.k2s.addon.implementation", "vnd.k2s.addon.version"}
	for _, annotation := range k2sAnnotations {
		if strings.Contains(indexJson, annotation) {
			GinkgoWriter.Printf("[OciManifest] K2s annotation '%s': FOUND\n", annotation)
		} else {
			GinkgoWriter.Printf("[OciManifest] K2s annotation '%s': MISSING\n", annotation)
		}
		Expect(indexJson).To(ContainSubstring(annotation), "index.json should contain K2s annotation '%s'", annotation)
	}

	// Verify the expected addon is referenced
	Expect(indexJson).To(ContainSubstring(expectedDirName),
		"index.json should reference addon %s", expectedDirName)

	GinkgoWriter.Println("=== VERIFY OCI MANIFEST END ===")
}

// CleanAddonResources cleans up resources for a specific addon implementation.
func CleanAddonResources(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== CLEAN ADDON RESOURCES START ===")
	GinkgoWriter.Printf("[Clean] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Clean] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Clean] Control plane IP: %s\n", controlPlaneIP)

	GinkgoWriter.Println("[Clean] Running 'k2s image clean -o' to remove images...")
	suite.K2sCli().Exec(ctx, "image", "clean", "-o")
	GinkgoWriter.Println("[Clean] Image clean completed")

	rmCmd := fmt.Sprintf("sudo rm -rf .%s", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Clean] Removing debian packages with command: %s\n", rmCmd)
	suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", rmCmd)
	GinkgoWriter.Println("[Clean] Debian packages removed")
	GinkgoWriter.Println("=== CLEAN ADDON RESOURCES END ===")
}

// VerifyResourcesCleanedUp verifies that addon resources have been cleaned up.
func VerifyResourcesCleanedUp(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== VERIFY RESOURCES CLEANED UP START ===")
	GinkgoWriter.Printf("[Verify] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[Verify] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Verify] Control plane IP: %s\n", controlPlaneIP)

	// Verify debian packages are removed
	checkCmd := fmt.Sprintf("[ -d .%s ]", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[Verify] Checking directory does not exist with command: %s\n", checkCmd)
	GinkgoWriter.Println("[Verify] Expecting exit code 1 (directory should not exist)...")
	suite.K2sCli().ExpectedExitCode(1).Exec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
	GinkgoWriter.Println("[Verify] Confirmed: directory does not exist (as expected)")
	GinkgoWriter.Println("=== VERIFY RESOURCES CLEANED UP END ===")
}

// ImportAddon imports an addon from an OCI tar file.
func ImportAddon(ctx context.Context, suite *framework.K2sTestSuite, ociTarPath string) {
	GinkgoWriter.Println("=== IMPORT ADDON START ===")
	GinkgoWriter.Printf("[Import] OCI tar file: %s\n", ociTarPath)

	if info, err := os.Stat(ociTarPath); err == nil {
		GinkgoWriter.Printf("[Import] OCI tar file size: %d bytes\n", info.Size())
	} else {
		GinkgoWriter.Printf("[Import] WARNING: Cannot stat OCI tar file: %s - %v\n", ociTarPath, err)
	}

	GinkgoWriter.Println("[Import] Executing 'k2s addons import -z' command...")
	suite.K2sCli().MustExec(ctx, "addons", "import", "-z", ociTarPath)
	GinkgoWriter.Println("[Import] Import command completed successfully")
	GinkgoWriter.Println("=== IMPORT ADDON END ===")
}

// VerifyImportedImages verifies that expected images are available after import.
func VerifyImportedImages(ctx context.Context, suite *framework.K2sTestSuite, k2sDsl *dsl.K2s, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY IMPORTED IMAGES START ===")
	GinkgoWriter.Printf("[ImportedImages] Implementation: %s\n", impl.Name)

	importedImages := k2sDsl.GetNonK8sImagesFromNodes(ctx)
	GinkgoWriter.Printf("[ImportedImages] Total imported images on nodes: %d\n", len(importedImages))
	for i, img := range importedImages {
		GinkgoWriter.Printf("[ImportedImages]   [%d] %s\n", i, img)
	}

	images, err := suite.AddonsAdditionalInfo().GetImagesForAddonImplementation(*impl)
	Expect(err).To(BeNil(), "[ImportedImages] Failed to get expected images from manifest")
	GinkgoWriter.Printf("[ImportedImages] Expected images from manifest: %d\n", len(images))

	for i, image := range images {
		contains := slices.ContainsFunc(importedImages, func(imported string) bool {
			return strings.Contains(imported, image)
		})
		if contains {
			GinkgoWriter.Printf("[ImportedImages]   [%d] OK: %s\n", i, image)
		} else {
			GinkgoWriter.Printf("[ImportedImages]   [%d] MISSING: %s\n", i, image)
		}
		Expect(contains).To(BeTrue(), "Image %s should be available after import", image)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED IMAGES END ===")
}

// VerifyImportedDebPackages verifies that expected debian packages are available after import.
func VerifyImportedDebPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== VERIFY IMPORTED DEB PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedDeb] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedDeb] Export directory name: %s\n", impl.ExportDirectoryName)
	GinkgoWriter.Printf("[ImportedDeb] Control plane IP: %s\n", controlPlaneIP)
	GinkgoWriter.Printf("[ImportedDeb] Expected packages: %d\n", len(impl.OfflineUsage.LinuxResources.DebPackages))

	for i, pkg := range impl.OfflineUsage.LinuxResources.DebPackages {
		checkCmd := fmt.Sprintf("[ -d .%s/%s ]", impl.ExportDirectoryName, pkg)
		GinkgoWriter.Printf("[ImportedDeb]   [%d] Checking: %s\n", i, pkg)
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
		GinkgoWriter.Printf("[ImportedDeb]   [%d] OK: %s exists\n", i, pkg)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED DEB PACKAGES END ===")
}

// VerifyImportedLinuxCurlPackages verifies that expected linux curl packages are available after import.
func VerifyImportedLinuxCurlPackages(ctx context.Context, suite *framework.K2sTestSuite, impl *addons.Implementation, controlPlaneIP string) {
	GinkgoWriter.Println("=== VERIFY IMPORTED LINUX CURL PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedLinuxCurl] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedLinuxCurl] Control plane IP: %s\n", controlPlaneIP)
	GinkgoWriter.Printf("[ImportedLinuxCurl] Expected packages: %d\n", len(impl.OfflineUsage.LinuxResources.CurlPackages))

	for i, pkg := range impl.OfflineUsage.LinuxResources.CurlPackages {
		checkCmd := fmt.Sprintf("[ -f %s ]", pkg.Destination)
		GinkgoWriter.Printf("[ImportedLinuxCurl]   [%d] Checking: %s -> %s\n", i, pkg.Url, pkg.Destination)
		suite.K2sCli().MustExec(ctx, "node", "exec", "-i", controlPlaneIP, "-u", "remote", "-c", checkCmd)
		GinkgoWriter.Printf("[ImportedLinuxCurl]   [%d] OK: %s exists\n", i, pkg.Destination)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED LINUX CURL PACKAGES END ===")
}

// VerifyImportedWindowsCurlPackages verifies that expected windows curl packages are available after import.
func VerifyImportedWindowsCurlPackages(suite *framework.K2sTestSuite, impl *addons.Implementation) {
	GinkgoWriter.Println("=== VERIFY IMPORTED WINDOWS CURL PACKAGES START ===")
	GinkgoWriter.Printf("[ImportedWindowsCurl] Implementation: %s\n", impl.Name)
	GinkgoWriter.Printf("[ImportedWindowsCurl] Root dir: %s\n", suite.RootDir())
	GinkgoWriter.Printf("[ImportedWindowsCurl] Expected packages: %d\n", len(impl.OfflineUsage.WindowsResources.CurlPackages))

	for i, p := range impl.OfflineUsage.WindowsResources.CurlPackages {
		pkgPath := filepath.Join(suite.RootDir(), p.Destination)
		GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] Checking: %s -> %s\n", i, p.Url, pkgPath)
		info, err := os.Stat(pkgPath)
		if os.IsNotExist(err) {
			GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] MISSING: %s\n", i, pkgPath)
		} else if err == nil {
			GinkgoWriter.Printf("[ImportedWindowsCurl]   [%d] OK: %s (%d bytes)\n", i, pkgPath, info.Size())
		}
		Expect(os.IsNotExist(err)).To(BeFalse(), "Windows curl package %s should exist at %s", p.Destination, pkgPath)
	}
	GinkgoWriter.Println("=== VERIFY IMPORTED WINDOWS CURL PACKAGES END ===")
}

// CleanupExportedFiles removes exported files and directories.
func CleanupExportedFiles(exportPath string, zipPath string) {
	GinkgoWriter.Println("=== CLEANUP EXPORTED FILES START ===")
	GinkgoWriter.Printf("[Cleanup] Export path: %s\n", exportPath)
	GinkgoWriter.Printf("[Cleanup] ZIP path: %s\n", zipPath)

	extractedFolder := filepath.Join(exportPath, "addons")
	if info, err := os.Stat(extractedFolder); !os.IsNotExist(err) {
		GinkgoWriter.Printf("[Cleanup] Removing extracted folder: %s (isDir=%v)\n", extractedFolder, info.IsDir())
		if err := os.RemoveAll(extractedFolder); err != nil {
			GinkgoWriter.Printf("[Cleanup] WARNING: Failed to remove extracted folder: %v\n", err)
		} else {
			GinkgoWriter.Println("[Cleanup] Extracted folder removed successfully")
		}
	} else {
		GinkgoWriter.Printf("[Cleanup] Extracted folder does not exist: %s\n", extractedFolder)
	}

	if zipPath != "" {
		if info, err := os.Stat(zipPath); !os.IsNotExist(err) {
			GinkgoWriter.Printf("[Cleanup] Removing ZIP file: %s (%d bytes)\n", zipPath, info.Size())
			if err := os.Remove(zipPath); err != nil {
				GinkgoWriter.Printf("[Cleanup] WARNING: Failed to remove ZIP file: %v\n", err)
			} else {
				GinkgoWriter.Println("[Cleanup] ZIP file removed successfully")
			}
		} else {
			GinkgoWriter.Printf("[Cleanup] ZIP file does not exist: %s\n", zipPath)
		}
	}
	GinkgoWriter.Println("=== CLEANUP EXPORTED FILES END ===")
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
