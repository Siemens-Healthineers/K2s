// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

//go:build linux

package provider

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/siemens-healthineers/k2s/internal/definitions"
	kjson "github.com/siemens-healthineers/k2s/internal/json"
)

func createDummyScript(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		t.Fatalf("failed to create script dir: %v", err)
	}
	content := []byte("#!/bin/sh\nexit 0\n")
	if err := os.WriteFile(path, content, 0755); err != nil {
		t.Fatalf("failed to create dummy script: %v", err)
	}
}

func TestLinuxImageProvider_ScriptPath(t *testing.T) {
	p := &linuxImageProvider{installDir: "/test/k2s"}
	got := p.scriptPath("test.sh")
	want := filepath.Join("/test/k2s", "lib", "scripts", "linux", "debian", "host", "image", "test.sh")
	if got != want {
		t.Fatalf("scriptPath() = %q, want %q", got, want)
	}
}

func TestLinuxImageProvider_BuildRejectsWindows(t *testing.T) {
	p := &linuxImageProvider{installDir: "/test/k2s"}
	err := p.Build(ImageBuildConfig{Windows: true})
	if err == nil {
		t.Fatal("Build(Windows=true) expected error, got nil")
	}
	if !strings.Contains(err.Error(), "building Windows container images is not supported on Linux hosts") {
		t.Fatalf("unexpected error message: %v", err)
	}
}

func TestLinuxImageProvider_BuildExecutesScript(t *testing.T) {
	tmpDir := t.TempDir()
	p := &linuxImageProvider{installDir: tmpDir}
	script := p.scriptPath("Build-Image.sh")
	createDummyScript(t, script)

	err := p.Build(ImageBuildConfig{
		InputFolder: tmpDir,
		ImageName:   "myimage",
		ImageTag:    "v1",
		BuildArgs:   map[string]string{"KEY": "VAL"},
	})
	if err != nil {
		t.Fatalf("Build() failed: %v", err)
	}
}

func TestLinuxImageProvider_RegistryAddAndRemoveSyncsSetupJson(t *testing.T) {
	installDir := t.TempDir()
	configDir := t.TempDir()

	p := &linuxImageProvider{
		installDir: installDir,
		configDir:  configDir,
	}

	addScript := p.scriptPath(filepath.Join("registry", "Add-Registry.sh"))
	createDummyScript(t, addScript)

	rmScript := p.scriptPath(filepath.Join("registry", "Remove-Registry.sh"))
	createDummyScript(t, rmScript)

	// Create initial setup.json
	setupJsonPath := filepath.Join(configDir, definitions.K2sRuntimeConfigFileName)
	initialConfig := map[string]any{
		"SetupType":  "k2s",
		"LinuxOnly":  true,
		"Registries": []any{"existing.registry.io"},
	}
	if err := kjson.ToFile(setupJsonPath, &initialConfig); err != nil {
		t.Fatalf("failed to write initial setup.json: %v", err)
	}

	// RegistryAdd
	err := p.RegistryAdd(ImageRegistryAddConfig{
		RegistryName: "my.new.registry:5000",
		Username:     "user",
		Password:     "pass",
		SkipVerify:   true,
		PlainHttp:    true,
	})
	if err != nil {
		t.Fatalf("RegistryAdd() failed: %v", err)
	}

	// Verify setup.json contains both registries
	loadedConfig, err := kjson.FromFile[map[string]any](setupJsonPath)
	if err != nil {
		t.Fatalf("failed to read setup.json: %v", err)
	}
	regs := (*loadedConfig)["Registries"].([]any)
	if len(regs) != 2 {
		t.Fatalf("expected 2 registries, got %d: %v", len(regs), regs)
	}
	if regs[0] != "existing.registry.io" || regs[1] != "my.new.registry:5000" {
		t.Fatalf("unexpected registries list: %v", regs)
	}

	// RegistryAdd duplicate should not duplicate
	if err := p.RegistryAdd(ImageRegistryAddConfig{RegistryName: "my.new.registry:5000"}); err != nil {
		t.Fatalf("RegistryAdd() duplicate failed: %v", err)
	}
	loadedConfig, _ = kjson.FromFile[map[string]any](setupJsonPath)
	regs = (*loadedConfig)["Registries"].([]any)
	if len(regs) != 2 {
		t.Fatalf("expected 2 registries after adding duplicate, got %d", len(regs))
	}

	// RegistryRemove
	err = p.RegistryRemove(ImageRegistryRemoveConfig{
		RegistryName: "existing.registry.io",
	})
	if err != nil {
		t.Fatalf("RegistryRemove() failed: %v", err)
	}

	loadedConfig, err = kjson.FromFile[map[string]any](setupJsonPath)
	if err != nil {
		t.Fatalf("failed to read setup.json: %v", err)
	}
	regs = (*loadedConfig)["Registries"].([]any)
	if len(regs) != 1 || regs[0] != "my.new.registry:5000" {
		t.Fatalf("expected only 'my.new.registry:5000' remaining, got %v", regs)
	}
}

func TestLinuxImageProvider_DelegatesToScripts(t *testing.T) {
	installDir := t.TempDir()
	p := &linuxImageProvider{installDir: installDir}

	for _, script := range []string{
		"Clean-Images.sh",
		"Remove-Image.sh",
		"Export-Image.sh",
		"Import-Image.sh",
		"Pull-Image.sh",
		"Push-Image.sh",
		"Tag-Image.sh",
	} {
		createDummyScript(t, p.scriptPath(script))
	}

	if err := p.Clean(ImageCleanConfig{}); err != nil {
		t.Fatalf("Clean() failed: %v", err)
	}
	if err := p.Remove(ImageRemoveConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Remove() failed: %v", err)
	}
	if err := p.Export(ImageExportConfig{ImageName: "test", OutputPath: "/tmp/out.tar"}); err != nil {
		t.Fatalf("Export() failed: %v", err)
	}
	if err := p.Import(ImageImportConfig{TarPath: "/tmp/in.tar"}); err != nil {
		t.Fatalf("Import() failed: %v", err)
	}
	if err := p.Pull(ImagePullConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Pull() failed: %v", err)
	}
	if err := p.Push(ImagePushConfig{ImageName: "test"}); err != nil {
		t.Fatalf("Push() failed: %v", err)
	}
	if err := p.Tag(ImageTagConfig{ImageName: "test", TargetImageName: "test2"}); err != nil {
		t.Fatalf("Tag() failed: %v", err)
	}
}
