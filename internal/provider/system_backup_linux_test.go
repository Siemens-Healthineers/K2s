// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

//go:build linux

package provider

import (
	"archive/zip"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"gopkg.in/yaml.v3"
)

func TestLinuxSystemBackup(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "Linux System Backup Unit Tests", Label("unit", "ci", "linux", "backup"))
}

var _ = Describe("Linux System Backup", func() {
	Describe("splitAndTrim", func() {
		It("splits and trims comma-separated values", func() {
			input := "  item1,  item2 ,item3  , , item4 "
			expected := []string{"item1", "item2", "item3", "item4"}
			Expect(splitAndTrim(input)).To(Equal(expected))
		})

		It("returns nil for empty input", func() {
			Expect(splitAndTrim("")).To(BeNil())
		})
	})

	Describe("containsString", func() {
		It("matches strings case-insensitively", func() {
			slice := []string{"Kube-System", "DEFAULT"}
			Expect(containsString(slice, "kube-system")).To(BeTrue())
			Expect(containsString(slice, "Default")).To(BeTrue())
			Expect(containsString(slice, "other")).To(BeFalse())
		})
	})

	Describe("sanitizeImageName", func() {
		It("replaces special characters with underscores", func() {
			input := "docker.io/library/busybox:1.36@sha256:abcdef"
			expected := "docker.io_library_busybox_1.36_sha256_abcdef"
			Expect(sanitizeImageName(input)).To(Equal(expected))
		})
	})

	Describe("loadBackupConfig", func() {
		When("config.json does not exist", func() {
			It("returns default configuration values", func() {
				tempDir := GinkgoT().TempDir()
				cfg := loadBackupConfig(tempDir)

				Expect(cfg).NotTo(BeNil())
				Expect(cfg.ClusterName).To(Equal("k2s-cluster"))
				Expect(cfg.ExcludedNamespaces).To(ContainElement("kube-system"))
				Expect(cfg.ExcludedNamespacedResources).To(ContainElement("endpoints"))
				Expect(cfg.ExcludedClusterResources).To(ContainElement("nodes"))
				Expect(cfg.ExcludedAddonPersistentVolumes).To(ContainElement("postgresql-pv-volume"))
			})
		})

		When("config.json exists with custom exclusions", func() {
			It("loads the configured exclusions", func() {
				tempDir := GinkgoT().TempDir()
				cfgDir := filepath.Join(tempDir, "cfg")
				Expect(os.MkdirAll(cfgDir, 0755)).To(Succeed())

				customConfig := `{
					"smallsetup": {
						"backup": {
							"excludednamespaces": "custom-ns1,custom-ns2",
							"excludednamespacedresources": "custom-res1",
							"excludedclusterresources": "custom-cres1",
							"excludedaddonpersistentvolumes": "custom-pv1"
						}
					},
					"clusterName": "my-custom-cluster"
				}`
				Expect(os.WriteFile(filepath.Join(cfgDir, "config.json"), []byte(customConfig), 0644)).To(Succeed())

				cfg := loadBackupConfig(tempDir)
				Expect(cfg).NotTo(BeNil())
				Expect(cfg.ClusterName).To(Equal("my-custom-cluster"))
				Expect(cfg.ExcludedNamespaces).To(Equal([]string{"custom-ns1", "custom-ns2"}))
				Expect(cfg.ExcludedNamespacedResources).To(Equal([]string{"custom-res1"}))
				Expect(cfg.ExcludedClusterResources).To(Equal([]string{"custom-cres1"}))
				Expect(cfg.ExcludedAddonPersistentVolumes).To(Equal([]string{"custom-pv1"}))
			})
		})
	})

	Describe("cleanAndConvertResourceJSON", func() {
		It("returns false when items list is empty", func() {
			rawJSON := []byte(`{"apiVersion":"v1","items":[],"kind":"List","metadata":{"resourceVersion":""}}`)
			bytes, hasItems, err := cleanAndConvertResourceJSON(rawJSON)
			Expect(err).NotTo(HaveOccurred())
			Expect(hasItems).To(BeFalse())
			Expect(bytes).To(BeNil())
		})

		It("strips runtime metadata and converts to YAML when items are present", func() {
			rawJSON := []byte(`{
				"apiVersion": "v1",
				"kind": "List",
				"metadata": {
					"resourceVersion": "12345"
				},
				"items": [
					{
						"apiVersion": "v1",
						"kind": "ConfigMap",
						"metadata": {
							"name": "my-config",
							"namespace": "default",
							"uid": "abc-123",
							"resourceVersion": "999",
							"creationTimestamp": "2026-01-01T00:00:00Z",
							"generation": 1,
							"managedFields": [{"manager": "kubectl"}],
							"annotations": {
								"kubectl.kubernetes.io/last-applied-configuration": "{}",
								"custom.annotation": "keep-me"
							}
						},
						"data": {
							"key": "value"
						},
						"status": {
							"phase": "Active"
						}
					}
				]
			}`)

			bytes, hasItems, err := cleanAndConvertResourceJSON(rawJSON)
			Expect(err).NotTo(HaveOccurred())
			Expect(hasItems).To(BeTrue())

			var parsed map[string]any
			Expect(yaml.Unmarshal(bytes, &parsed)).To(Succeed())

			items := parsed["items"].([]any)
			Expect(items).To(HaveLen(1))
			item := items[0].(map[string]any)

			Expect(item).NotTo(HaveKey("status"))
			meta := item["metadata"].(map[string]any)
			Expect(meta["name"]).To(Equal("my-config"))
			Expect(meta).NotTo(HaveKey("uid"))
			Expect(meta).NotTo(HaveKey("resourceVersion"))
			Expect(meta).NotTo(HaveKey("creationTimestamp"))
			Expect(meta).NotTo(HaveKey("generation"))
			Expect(meta).NotTo(HaveKey("managedFields"))

			annotations := meta["annotations"].(map[string]any)
			Expect(annotations).To(HaveKeyWithValue("custom.annotation", "keep-me"))
			Expect(annotations).NotTo(HaveKey("kubectl.kubernetes.io/last-applied-configuration"))
		})
	})

	Describe("generateBackupManifest", func() {
		It("writes a valid backup.json file", func() {
			tempDir := GinkgoT().TempDir()
			bcfg := &backupConfig{
				ExcludedNamespaces:          []string{"kube-system"},
				ExcludedNamespacedResources: []string{"endpoints"},
				ExcludedClusterResources:    []string{"nodes"},
				ClusterName:                 "test-cluster",
			}

			err := generateBackupManifest(tempDir, bcfg, []string{"default", "my-app"})
			Expect(err).NotTo(HaveOccurred())

			manifestPath := filepath.Join(tempDir, "backup.json")
			Expect(manifestPath).To(BeAnExistingFile())

			data, err := os.ReadFile(manifestPath)
			Expect(err).NotTo(HaveOccurred())

			var manifest backupManifest
			Expect(json.Unmarshal(data, &manifest)).To(Succeed())

			Expect(manifest.APIVersion).To(Equal("k2s.backup/v1"))
			Expect(manifest.Kind).To(Equal("SystemBackup"))
			Expect(manifest.Metadata.BackupTool).To(Equal("k2s system backup"))
			Expect(manifest.Metadata.BackupFormatVersion).To(Equal("1"))
			Expect(manifest.Cluster.Name).To(Equal("test-cluster"))
			Expect(manifest.Content.Included.ClusterResources).To(BeTrue())
			Expect(manifest.Content.Included.Namespaces).To(Equal([]string{"default", "my-app"}))
			Expect(manifest.Content.Excluded.Namespaces).To(Equal([]string{"kube-system"}))
			Expect(manifest.ConfigSnapshot.Source).To(Equal("config/config.json"))
		})
	})

	Describe("createZipFromDirectory", func() {
		It("creates a valid zip archive containing relative paths", func() {
			stagingDir := GinkgoT().TempDir()
			zipDest := filepath.Join(GinkgoT().TempDir(), "backup.zip")

			// Create test files and directories
			Expect(os.WriteFile(filepath.Join(stagingDir, "backup.json"), []byte("{}"), 0644)).To(Succeed())
			cfgSubDir := filepath.Join(stagingDir, "config")
			Expect(os.MkdirAll(cfgSubDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(cfgSubDir, "config.json"), []byte("{}"), 0644)).To(Succeed())
			nsSubDir := filepath.Join(stagingDir, "Namespaced", "default")
			Expect(os.MkdirAll(nsSubDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(nsSubDir, "pods.yaml"), []byte("apiVersion: v1"), 0644)).To(Succeed())

			err := createZipFromDirectory(stagingDir, zipDest)
			Expect(err).NotTo(HaveOccurred())
			Expect(zipDest).To(BeAnExistingFile())

			zr, err := zip.OpenReader(zipDest)
			Expect(err).NotTo(HaveOccurred())
			defer zr.Close()

			var fileNames []string
			for _, f := range zr.File {
				fileNames = append(fileNames, f.Name)
			}

			Expect(fileNames).To(ContainElement("backup.json"))
			Expect(fileNames).To(ContainElement("config/config.json"))
			Expect(fileNames).To(ContainElement("Namespaced/default/pods.yaml"))
		})
	})

	Describe("tarGzDirectory and tarGzSingleFile", func() {
		It("archives a directory to tar.gz", func() {
			srcDir := GinkgoT().TempDir()
			destTarGz := filepath.Join(GinkgoT().TempDir(), "archive.tar.gz")

			Expect(os.WriteFile(filepath.Join(srcDir, "test.txt"), []byte("hello world"), 0644)).To(Succeed())

			err := tarGzDirectory(srcDir, destTarGz)
			Expect(err).NotTo(HaveOccurred())
			Expect(destTarGz).To(BeAnExistingFile())
		})

		It("archives a single file to tar.gz", func() {
			srcFile := filepath.Join(GinkgoT().TempDir(), "single.txt")
			destTarGz := filepath.Join(GinkgoT().TempDir(), "single.tar.gz")

			Expect(os.WriteFile(srcFile, []byte("single file content"), 0644)).To(Succeed())

			err := tarGzSingleFile(srcFile, destTarGz)
			Expect(err).NotTo(HaveOccurred())
			Expect(destTarGz).To(BeAnExistingFile())
		})
	})

	Describe("executeBackupHooks", func() {
		It("skips hooks for disabled addons without error", func() {
			installDir := GinkgoT().TempDir()
			stagingDir := GinkgoT().TempDir()

			addonHookDir := filepath.Join(installDir, "addons", "disabled-addon")
			Expect(os.MkdirAll(addonHookDir, 0755)).To(Succeed())
			Expect(os.WriteFile(filepath.Join(addonHookDir, "Backup.sh"), []byte("#!/bin/sh\nexit 0\n"), 0755)).To(Succeed())

			Expect(func() {
				executeBackupHooks(installDir, stagingDir, "")
			}).NotTo(Panic())
		})
	})
})
