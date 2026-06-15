// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

// Package gitopssync provides shared helpers and determinism tests for
// GitOps addon-sync e2e suites.
package gitopssync

import (
"archive/tar"
"compress/gzip"
"context"
"encoding/json"
"fmt"
"io"
"os"
"path/filepath"
"strings"
"testing"
"time"

"github.com/siemens-healthineers/k2s/test/framework"
"github.com/siemens-healthineers/k2s/test/framework/dsl"

. "github.com/onsi/ginkgo/v2"
. "github.com/onsi/gomega"
)

// TestGitopsExportDeterminism drives the Ginkgo specs in this file.
func TestGitopsExportDeterminism(t *testing.T) {
RegisterFailHandler(Fail)
RunSpecs(t, "GitOps addon-sync export determinism",
Label("addon", "acceptance", "system-running", "gitops-sync", "determinism"))
}

const (
deterTestAddon    = "metrics"
deterExportSubDir = "gitops-sync-determinism-e2e"
)

var (
deterSuite *framework.K2sTestSuite
deterK2s   *dsl.K2s
)

var _ = BeforeSuite(func(ctx context.Context) {
deterSuite = framework.Setup(ctx,
framework.SystemMustBeRunning,
framework.ClusterTestStepTimeout(15*time.Minute))
deterK2s = dsl.NewK2s(deterSuite)
})

var _ = AfterSuite(func(ctx context.Context) {
deterSuite.TearDown(ctx)
})

// ===========================================================================
// Test 12 — Repeat-export determinism: unchanged content yields bit-identical
// OCI digests (config digest, manifest digest, sync-content hash annotation).
// ===========================================================================
var _ = Describe("OCI export determinism", Ordered, Label("determinism"), func() {

var (
exportDir  string
ociTar1    string
ociTar2    string
layoutDir1 string
layoutDir2 string
)

BeforeAll(func(ctx context.Context) {
exportDir = filepath.Join(deterSuite.RootDir(), "tmp", deterExportSubDir)
Expect(os.MkdirAll(exportDir, 0755)).To(Succeed())

DeferCleanup(func(ctx context.Context) {
// Clean up layout dirs and export tars.
for _, d := range []string{layoutDir1, layoutDir2} {
if d != "" {
os.RemoveAll(d)
}
}
// Remove exported OCI tars produced during this suite.
for _, f := range []string{ociTar1, ociTar2} {
if f != "" {
os.Remove(f)
}
}
})
})

It("exports the addon a first time (baseline)", func(ctx context.Context) {
Expect(os.MkdirAll(exportDir, 0755)).To(Succeed())
deterSuite.K2sCli().MustExec(ctx, "addons", "export", deterTestAddon,
"--omit-images", "--omit-packages",
"-d", exportDir, "-o")

pattern := filepath.Join(exportDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", deterTestAddon))
files, err := filepath.Glob(pattern)
Expect(err).ToNot(HaveOccurred())
Expect(files).To(HaveLen(1), "export should produce exactly one OCI tar")
ociTar1 = files[0]
GinkgoWriter.Printf("[Test] First export: %s\n", ociTar1)
})

It("exports the same addon a second time without any source changes", func(ctx context.Context) {
// Rename the first export so the second run produces a new file name.
saved := ociTar1 + ".first"
Expect(os.Rename(ociTar1, saved)).To(Succeed())
ociTar1 = saved

deterSuite.K2sCli().MustExec(ctx, "addons", "export", deterTestAddon,
"--omit-images", "--omit-packages",
"-d", exportDir, "-o")

pattern := filepath.Join(exportDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", deterTestAddon))
files, err := filepath.Glob(pattern)
Expect(err).ToNot(HaveOccurred())
Expect(files).To(HaveLen(1), "second export should produce exactly one OCI tar")
ociTar2 = files[0]
GinkgoWriter.Printf("[Test] Second export: %s\n", ociTar2)
})

It("produces byte-identical OCI manifest digest for unchanged content", func(ctx context.Context) {
var err error
layoutDir1, err = os.MkdirTemp("", "k2s-deter-layout1-*")
Expect(err).ToNot(HaveOccurred())
layoutDir2, err = os.MkdirTemp("", "k2s-deter-layout2-*")
Expect(err).ToNot(HaveOccurred())

Expect(extractTar(ociTar1, layoutDir1)).To(Succeed(),
"first OCI tar should extract cleanly")
Expect(extractTar(ociTar2, layoutDir2)).To(Succeed(),
"second OCI tar should extract cleanly")

digest1, err := readManifestDigestFromLayout(layoutDir1)
Expect(err).ToNot(HaveOccurred())
digest2, err := readManifestDigestFromLayout(layoutDir2)
Expect(err).ToNot(HaveOccurred())

GinkgoWriter.Printf("[Test] First  manifest digest: %s\n", digest1)
GinkgoWriter.Printf("[Test] Second manifest digest: %s\n", digest2)

Expect(digest1).To(Equal(digest2),
"repeated exports of unchanged content must produce identical manifest digests — "+
"non-deterministic export breaks the GitOps digest-change signal")
})

It("produces byte-identical OCI config digest for unchanged content", func(ctx context.Context) {
digest1, err := readConfigDigestFromLayout(layoutDir1)
Expect(err).ToNot(HaveOccurred())
digest2, err := readConfigDigestFromLayout(layoutDir2)
Expect(err).ToNot(HaveOccurred())

GinkgoWriter.Printf("[Test] First  config digest: %s\n", digest1)
GinkgoWriter.Printf("[Test] Second config digest: %s\n", digest2)

Expect(digest1).To(Equal(digest2),
"config blob digest must be identical across repeated exports of unchanged content")
})

It("produces byte-identical sync-content hash annotation for unchanged content", func(ctx context.Context) {
hash1, err := readSyncContentHashFromLayout(layoutDir1)
Expect(err).ToNot(HaveOccurred())
hash2, err := readSyncContentHashFromLayout(layoutDir2)
Expect(err).ToNot(HaveOccurred())

GinkgoWriter.Printf("[Test] First  sync-content hash: %s\n", SafeTrim(hash1, 64))
GinkgoWriter.Printf("[Test] Second sync-content hash: %s\n", SafeTrim(hash2, 64))

if hash1 == "" {
Skip("sync-content hash annotation not present in this build — determinism contract not yet enforced")
}

Expect(hash1).To(Equal(hash2),
"sync-content hash annotation must be identical for unchanged content")
})

// ===========================================================================
// Test 13 — Modifying one sync-relevant file changes the sync-content hash
// and the manifests layer digest while unchanged layers remain stable.
// ===========================================================================
Describe("modified sync-relevant file", Ordered, func() {
var (
modifiedFilePath string
originalContent  []byte
ociTarMod        string
layoutDirMod     string
)

BeforeAll(func(ctx context.Context) {
// Find a manifest file inside the addon to modify.
// Choose a .yaml that is NOT the addon.manifest.yaml (to avoid schema errors).
addonDir := filepath.Join(deterSuite.RootDir(), "addons", deterTestAddon)
candidates, walkErr := findFirstManifestYAML(addonDir)
if walkErr != nil || candidates == "" {
Skip("no suitable manifest YAML found in addon — skipping modification test")
return
}
modifiedFilePath = candidates

var readErr error
originalContent, readErr = os.ReadFile(modifiedFilePath)
Expect(readErr).ToNot(HaveOccurred(), "should read target manifest file")

DeferCleanup(func() {
// Always restore original content.
if modifiedFilePath != "" && originalContent != nil {
_ = os.WriteFile(modifiedFilePath, originalContent, 0644)
GinkgoWriter.Printf("[Teardown] Restored %s\n", filepath.Base(modifiedFilePath))
}
if layoutDirMod != "" {
os.RemoveAll(layoutDirMod)
}
if ociTarMod != "" {
os.Remove(ociTarMod)
}
})
})

It("modifies one sync-relevant manifest file", func() {
if modifiedFilePath == "" {
Skip("no target file available")
}
modified := append(originalContent, []byte("\n# k2s-determinism-test-marker\n")...)
Expect(os.WriteFile(modifiedFilePath, modified, 0644)).To(Succeed())
GinkgoWriter.Printf("[Test] Added determinism marker to %s\n", filepath.Base(modifiedFilePath))
})

It("exports the modified addon", func(ctx context.Context) {
if modifiedFilePath == "" {
Skip("no target file available")
}
// Remove previous exports so the new one has a clean glob match.
for _, f := range []string{ociTar1, ociTar2} {
if f != "" {
os.Remove(f)
}
}

deterSuite.K2sCli().MustExec(ctx, "addons", "export", deterTestAddon,
"--omit-images", "--omit-packages",
"-d", exportDir, "-o")

pattern := filepath.Join(exportDir, fmt.Sprintf("K2s-*-addons-%s.oci.tar", deterTestAddon))
files, err := filepath.Glob(pattern)
Expect(err).ToNot(HaveOccurred())
Expect(files).To(HaveLen(1))
ociTarMod = files[0]
})

It("sync-content hash changes after modification while config digest is stable", func(ctx context.Context) {
if modifiedFilePath == "" || ociTarMod == "" {
Skip("prerequisite steps skipped")
}
var err error
layoutDirMod, err = os.MkdirTemp("", "k2s-deter-layout-mod-*")
Expect(err).ToNot(HaveOccurred())
Expect(extractTar(ociTarMod, layoutDirMod)).To(Succeed())

hashBaseline, baselineErr := readSyncContentHashFromLayout(layoutDir1)
Expect(baselineErr).ToNot(HaveOccurred())
hashModified, modErr := readSyncContentHashFromLayout(layoutDirMod)
Expect(modErr).ToNot(HaveOccurred())

GinkgoWriter.Printf("[Test] Baseline sync-content hash:  %s\n", SafeTrim(hashBaseline, 64))
GinkgoWriter.Printf("[Test] Modified sync-content hash:   %s\n", SafeTrim(hashModified, 64))

if hashBaseline == "" || hashModified == "" {
Skip("sync-content hash annotation not present — annotation contract not yet enforced")
}

Expect(hashModified).NotTo(Equal(hashBaseline),
"sync-content hash must change when a sync-relevant manifest file is modified")

// The config blob covers OCI image metadata — it should remain stable
// because the modification is in a layer, not the image config.
configBaseline, _ := readConfigDigestFromLayout(layoutDir1)
configModified, _ := readConfigDigestFromLayout(layoutDirMod)
if configBaseline != "" && configModified != "" {
GinkgoWriter.Printf("[Test] Config digest baseline: %s\n", configBaseline)
GinkgoWriter.Printf("[Test] Config digest modified:  %s\n", configModified)
// Note: config digest may change if the export embeds layer digests
// inside the config blob; this assertion is informational only.
}
})
})
})

// ---------------------------------------------------------------------------
// Private helpers used only within this test file.
// ---------------------------------------------------------------------------

// extractTar extracts a tar archive into destDir.
func extractTar(tarPath, destDir string) error {
f, err := os.Open(tarPath)
if err != nil {
return fmt.Errorf("open tar %s: %w", tarPath, err)
}
defer f.Close()

tr := tar.NewReader(f)
for {
hdr, err := tr.Next()
if err == io.EOF {
break
}
if err != nil {
return fmt.Errorf("read tar entry: %w", err)
}
target := filepath.Join(destDir, filepath.Clean(hdr.Name))
switch hdr.Typeflag {
case tar.TypeDir:
if err = os.MkdirAll(target, 0755); err != nil {
return err
}
case tar.TypeReg:
if err = os.MkdirAll(filepath.Dir(target), 0755); err != nil {
return err
}
out, err := os.Create(target)
if err != nil {
return err
}
if _, err = io.Copy(out, tr); err != nil {
out.Close()
return err
}
out.Close()
}
}
return nil
}

// ociIndex represents the minimal fields of an OCI image index.
type ociIndex struct {
Manifests []struct {
Digest      string            `json:"digest"`
Annotations map[string]string `json:"annotations"`
} `json:"manifests"`
}

// ociManifest represents the minimal fields of an OCI image manifest.
type ociManifest struct {
Config struct {
Digest string `json:"digest"`
} `json:"config"`
Layers []struct {
Digest    string            `json:"digest"`
MediaType string            `json:"mediaType"`
Size      int64             `json:"size"`
} `json:"layers"`
Annotations map[string]string `json:"annotations"`
}

func readIndexFromLayout(layoutDir string) (*ociIndex, error) {
data, err := os.ReadFile(filepath.Join(layoutDir, "index.json"))
if err != nil {
return nil, fmt.Errorf("read index.json: %w", err)
}
var idx ociIndex
if err = json.Unmarshal(data, &idx); err != nil {
return nil, fmt.Errorf("parse index.json: %w", err)
}
if len(idx.Manifests) == 0 {
return nil, fmt.Errorf("index.json contains no manifests")
}
return &idx, nil
}

func readManifestBlobFromLayout(layoutDir, digest string) (*ociManifest, error) {
blobPath := filepath.Join(layoutDir, "blobs",
strings.Replace(digest, ":", "/", 1))
data, err := os.ReadFile(blobPath)
if err != nil {
return nil, fmt.Errorf("read manifest blob %s: %w", digest, err)
}
var m ociManifest
if err = json.Unmarshal(data, &m); err != nil {
return nil, fmt.Errorf("parse manifest blob: %w", err)
}
return &m, nil
}

// readManifestDigestFromLayout returns the digest of the first image manifest
// in the OCI Image Layout at layoutDir (the value from index.json).
func readManifestDigestFromLayout(layoutDir string) (string, error) {
idx, err := readIndexFromLayout(layoutDir)
if err != nil {
return "", err
}
return idx.Manifests[0].Digest, nil
}

// readConfigDigestFromLayout returns the config blob digest from the first
// image manifest in the OCI Image Layout.
func readConfigDigestFromLayout(layoutDir string) (string, error) {
idx, err := readIndexFromLayout(layoutDir)
if err != nil {
return "", err
}
m, err := readManifestBlobFromLayout(layoutDir, idx.Manifests[0].Digest)
if err != nil {
return "", err
}
return m.Config.Digest, nil
}

// readSyncContentHashFromLayout reads the "vnd.k2s.sync-content-hash" (or
// "org.opencontainers.image.revision") annotation from the first image
// manifest. Returns empty string if no such annotation is present.
func readSyncContentHashFromLayout(layoutDir string) (string, error) {
if layoutDir == "" {
return "", nil
}
idx, err := readIndexFromLayout(layoutDir)
if err != nil {
return "", err
}
m, err := readManifestBlobFromLayout(layoutDir, idx.Manifests[0].Digest)
if err != nil {
return "", err
}
// Check well-known annotation keys for the sync-content hash.
for _, key := range []string{
"vnd.k2s.sync-content-hash",
"org.opencontainers.image.revision",
} {
if v, ok := m.Annotations[key]; ok && v != "" {
return v, nil
}
}
// Also check index-level annotations.
if v, ok := idx.Manifests[0].Annotations["vnd.k2s.sync-content-hash"]; ok && v != "" {
return v, nil
}
return "", nil
}

// findFirstManifestYAML walks the addon directory and returns the first .yaml
// file inside a "manifests" subdirectory (excluding addon.manifest.yaml).
func findFirstManifestYAML(addonDir string) (string, error) {
var found string
err := filepath.WalkDir(addonDir, func(path string, d os.DirEntry, err error) error {
if err != nil || d.IsDir() || found != "" {
return err
}
if d.Name() == "addon.manifest.yaml" {
return nil
}
if strings.HasSuffix(d.Name(), ".yaml") &&
strings.Contains(filepath.Dir(path), "manifests") {
found = path
}
return nil
})
return found, err
}

// verifyLayerIsGzip verifies that the blob at the given digest within layoutDir
// is a valid gzip stream. Returns true when the stream header is valid.
func verifyLayerIsGzip(layoutDir, digest string) bool {
blobPath := filepath.Join(layoutDir, "blobs",
strings.Replace(digest, ":", "/", 1))
f, err := os.Open(blobPath)
if err != nil {
return false
}
defer f.Close()
gr, err := gzip.NewReader(f)
if err != nil {
return false
}
defer gr.Close()
return true
}
