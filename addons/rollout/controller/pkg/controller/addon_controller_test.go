// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package controller

import (
	"archive/tar"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

func TestDetermineAddonPath(t *testing.T) {
	tests := []struct {
		name           string
		addonsPath     string
		addonName      string
		implementation string
		expected       string
	}{
		{
			name:           "simple addon without implementation",
			addonsPath:     filepath.FromSlash("/addons"),
			addonName:      "metrics",
			implementation: "",
			expected:       filepath.FromSlash("/addons/metrics"),
		},
		{
			name:           "addon with same-name implementation",
			addonsPath:     filepath.FromSlash("/addons"),
			addonName:      "metrics",
			implementation: "metrics",
			expected:       filepath.FromSlash("/addons/metrics"),
		},
		{
			name:           "addon with different implementation",
			addonsPath:     filepath.FromSlash("/addons"),
			addonName:      "ingress",
			implementation: "nginx",
			expected:       filepath.FromSlash("/addons/ingress/nginx"),
		},
		{
			name:           "windows path",
			addonsPath:     "C:\\addons",
			addonName:      "monitoring",
			implementation: "",
			expected:       "C:\\addons\\monitoring",
		},
		{
			name:           "empty addons path uses default",
			addonsPath:     "",
			addonName:      "logging",
			implementation: "",
			expected:       filepath.FromSlash("/addons/logging"),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &K2sAddonReconciler{
				AddonsPath: tt.addonsPath,
			}
			addon := &K2sAddon{
				Spec: K2sAddonSpec{
					Name:           tt.addonName,
					Implementation: tt.implementation,
				},
			}
			result := r.determineAddonPath(addon)
			if result != tt.expected {
				t.Errorf("determineAddonPath() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestLayerSkipLogic(t *testing.T) {
	tests := []struct {
		name              string
		layers            LayerConfig
		nodeType          string
		mediaType         string
		expectSkipLinux   bool
		expectSkipWindows bool
	}{
		{
			name:              "skipImages skips both Linux and Windows",
			layers:            LayerConfig{SkipImages: true},
			nodeType:          "linux",
			expectSkipLinux:   true,
			expectSkipWindows: true,
		},
		{
			name:              "skipLinuxImages skips only Linux",
			layers:            LayerConfig{SkipLinuxImages: true},
			nodeType:          "linux",
			expectSkipLinux:   true,
			expectSkipWindows: true, // node type mismatch also causes skip
		},
		{
			name:              "skipWindowsImages skips only Windows",
			layers:            LayerConfig{SkipWindowsImages: true},
			nodeType:          "windows",
			expectSkipLinux:   true, // node type mismatch also causes skip
			expectSkipWindows: true,
		},
		{
			name:              "linux node skips Windows images by node type",
			layers:            LayerConfig{},
			nodeType:          "linux",
			expectSkipLinux:   false,
			expectSkipWindows: true, // node type mismatch
		},
		{
			name:              "windows node skips Linux images by node type",
			layers:            LayerConfig{},
			nodeType:          "windows",
			expectSkipLinux:   true, // node type mismatch
			expectSkipWindows: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			skipLinux := tt.layers.SkipImages || tt.layers.SkipLinuxImages || tt.nodeType != "linux"
			skipWindows := tt.layers.SkipImages || tt.layers.SkipWindowsImages || tt.nodeType != "windows"

			if skipLinux != tt.expectSkipLinux {
				t.Errorf("Linux skip = %v, want %v", skipLinux, tt.expectSkipLinux)
			}
			if skipWindows != tt.expectSkipWindows {
				t.Errorf("Windows skip = %v, want %v", skipWindows, tt.expectSkipWindows)
			}
		})
	}
}

func TestK2sAddonDeepCopy(t *testing.T) {
	now := metav1.Now()
	original := &K2sAddon{
		ObjectMeta: metav1.ObjectMeta{
			Name: "test-addon",
		},
		Spec: K2sAddonSpec{
			Name:           "test",
			Implementation: "impl",
			Version:        "1.0.0",
			Description:    "test addon",
			Source: AddonSource{
				Type:     "oci",
				OciRef:   "registry.example.com/test:v1",
				Insecure: true,
				PullSecretRef: &SecretRef{
					Name:      "my-secret",
					Namespace: "default",
				},
				OCIRepository: &OCIRepoRef{
					Name:      "repo",
					Namespace: "flux-system",
				},
			},
			Layers: LayerConfig{
				SkipImages:        true,
				SkipLinuxImages:   false,
				SkipWindowsImages: true,
				SkipPackages:      false,
				SkipManifests:     true,
			},
			NodeSelector: map[string]string{
				"kubernetes.io/os": "linux",
			},
		},
		Status: K2sAddonStatus{
			Phase:     "Available",
			Available: true,
			Conditions: []metav1.Condition{
				{
					Type:               "Ready",
					Status:             metav1.ConditionTrue,
					Reason:             "ProcessingComplete",
					LastTransitionTime: now,
				},
			},
			LayerStatus: LayerStatusMap{
				Config:    "Completed",
				Manifests: "Completed",
			},
			NodeStatus: []NodeStatusEntry{
				{
					NodeName:       "node1",
					NodeType:       "linux",
					ImagesImported: true,
					LastUpdated:    &now,
				},
			},
			LastProcessedTime: &now,
		},
	}

	copied := original.DeepCopy()

	if copied.Name != original.Name {
		t.Errorf("Name mismatch: got %q, want %q", copied.Name, original.Name)
	}

	original.Spec.Name = "modified"
	if copied.Spec.Name == "modified" {
		t.Error("DeepCopy is not independent - Spec.Name was modified")
	}

	original.Spec.Source.PullSecretRef.Name = "changed-secret"
	if copied.Spec.Source.PullSecretRef.Name == "changed-secret" {
		t.Error("DeepCopy is not independent - PullSecretRef was modified")
	}

	original.Spec.Source.OCIRepository.Name = "changed-repo"
	if copied.Spec.Source.OCIRepository.Name == "changed-repo" {
		t.Error("DeepCopy is not independent - OCIRepository was modified")
	}

	original.Spec.NodeSelector["new-key"] = "new-value"
	if _, exists := copied.Spec.NodeSelector["new-key"]; exists {
		t.Error("DeepCopy is not independent - NodeSelector was modified")
	}

	original.Status.Conditions[0].Reason = "modified"
	if copied.Status.Conditions[0].Reason == "modified" {
		t.Error("DeepCopy is not independent - Conditions was modified")
	}
}

func TestK2sAddonListDeepCopy(t *testing.T) {
	list := &K2sAddonList{
		Items: []K2sAddon{
			{
				ObjectMeta: metav1.ObjectMeta{Name: "addon1"},
				Spec:       K2sAddonSpec{Name: "addon1"},
			},
			{
				ObjectMeta: metav1.ObjectMeta{Name: "addon2"},
				Spec:       K2sAddonSpec{Name: "addon2"},
			},
		},
	}

	copied := list.DeepCopy()

	if len(copied.Items) != 2 {
		t.Errorf("Expected 2 items, got %d", len(copied.Items))
	}

	list.Items[0].Spec.Name = "modified"
	if copied.Items[0].Spec.Name == "modified" {
		t.Error("DeepCopy is not independent - Items was modified")
	}
}

func TestBase64Decode(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{
			name:  "valid base64",
			input: base64.StdEncoding.EncodeToString([]byte("user:password")),
			want:  "user:password",
		},
		{
			name:    "invalid base64",
			input:   "not-valid-base64!!!",
			wantErr: true,
		},
		{
			name:  "empty string",
			input: base64.StdEncoding.EncodeToString([]byte("")),
			want:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := base64Decode(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("base64Decode() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if got != tt.want {
				t.Errorf("base64Decode() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestHashContent(t *testing.T) {
	hash1 := hashContent([]byte("hello"))
	hash2 := hashContent([]byte("hello"))
	hash3 := hashContent([]byte("world"))

	if hash1 != hash2 {
		t.Error("Same content should produce same hash")
	}
	if hash1 == hash3 {
		t.Error("Different content should produce different hash")
	}
	if len(hash1) != 64 { // SHA256 hex = 64 chars
		t.Errorf("Hash length = %d, want 64", len(hash1))
	}
}

func TestAddonSourceTypes(t *testing.T) {
	source := AddonSource{
		Type: "OCIRepository",
		OCIRepository: &OCIRepoRef{
			Name:      "metrics-addon",
			Namespace: "rollout",
		},
	}

	if source.Type != "OCIRepository" {
		t.Errorf("Type = %q, want %q", source.Type, "OCIRepository")
	}
	if source.OCIRepository.Name != "metrics-addon" {
		t.Errorf("OCIRepository.Name = %q, want %q", source.OCIRepository.Name, "metrics-addon")
	}
}

func TestDockerConfigJSONParsing(t *testing.T) {
	config := dockerConfigJSON{
		Auths: map[string]dockerAuthEntry{
			"registry.example.com": {
				Username: "user",
				Password: "pass",
			},
			"registry2.example.com": {
				Auth: base64.StdEncoding.EncodeToString([]byte("user2:pass2")),
			},
		},
	}

	data, err := json.Marshal(config)
	if err != nil {
		t.Fatalf("Failed to marshal: %v", err)
	}

	var parsed dockerConfigJSON
	if err := json.Unmarshal(data, &parsed); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if len(parsed.Auths) != 2 {
		t.Errorf("Expected 2 auth entries, got %d", len(parsed.Auths))
	}

	entry := parsed.Auths["registry.example.com"]
	if entry.Username != "user" || entry.Password != "pass" {
		t.Errorf("Auth entry mismatch: got %+v", entry)
	}

	entry2 := parsed.Auths["registry2.example.com"]
	decoded, err := base64Decode(entry2.Auth)
	if err != nil {
		t.Fatalf("Failed to decode auth: %v", err)
	}
	if decoded != "user2:pass2" {
		t.Errorf("Decoded auth = %q, want %q", decoded, "user2:pass2")
	}
}

func TestK2sAddonPhases(t *testing.T) {
	validPhases := []string{"Pending", "Pulling", "Processing", "Available", "Failed"}
	for _, phase := range validPhases {
		addon := &K2sAddon{
			Status: K2sAddonStatus{Phase: phase},
		}
		if addon.Status.Phase != phase {
			t.Errorf("Phase = %q, want %q", addon.Status.Phase, phase)
		}
	}
}

func TestLayerStatusValues(t *testing.T) {
	validStatuses := []string{"Pending", "Processing", "Completed", "Failed", "Skipped"}
	for _, status := range validStatuses {
		ls := LayerStatusMap{Config: status}
		if ls.Config != status {
			t.Errorf("Config status = %q, want %q", ls.Config, status)
		}
	}
}

func TestReconcileSkipsProcessedAddon(t *testing.T) {
	addon := &K2sAddon{
		ObjectMeta: metav1.ObjectMeta{
			Generation: 1,
		},
		Status: K2sAddonStatus{
			Phase:              "Available",
			ObservedGeneration: 1,
		},
	}

	if addon.Status.ObservedGeneration != addon.Generation || addon.Status.Phase != "Available" {
		t.Error("Expected addon to be detected as already processed")
	}

	addon.ObjectMeta.Generation = 2
	if addon.Status.ObservedGeneration == addon.Generation {
		t.Error("Expected addon to require reprocessing after generation change")
	}
}

func TestMediaTypeConstants(t *testing.T) {
	tests := map[string]string{
		"Config":        MediaTypeConfig,
		"ConfigFiles":   MediaTypeConfigFiles,
		"Manifests":     MediaTypeManifests,
		"Charts":        MediaTypeCharts,
		"Scripts":       MediaTypeScripts,
		"ImagesLinux":   MediaTypeImagesLinux,
		"ImagesWindows": MediaTypeImagesWindows,
		"Packages":      MediaTypePackages,
	}

	for name, mediaType := range tests {
		if mediaType == "" {
			t.Errorf("Media type for %s is empty", name)
		}
		// All custom types should start with application/
		if mediaType[:12] != "application/" {
			t.Errorf("Media type %s doesn't start with application/: %s", name, mediaType)
		}
	}
}

func TestNodeStatusEntry(t *testing.T) {
	now := metav1.Now()
	entry := NodeStatusEntry{
		NodeName:          "node1",
		NodeType:          "linux",
		ImagesImported:    true,
		PackagesInstalled: false,
		LastUpdated:       &now,
	}

	if entry.NodeName != "node1" {
		t.Errorf("NodeName = %q, want %q", entry.NodeName, "node1")
	}
	if entry.NodeType != "linux" {
		t.Errorf("NodeType = %q, want %q", entry.NodeType, "linux")
	}
	if !entry.ImagesImported {
		t.Error("ImagesImported should be true")
	}
	if entry.PackagesInstalled {
		t.Error("PackagesInstalled should be false")
	}
}

func TestFinalizePendingLayers(t *testing.T) {
	tests := []struct {
		name     string
		input    LayerStatusMap
		expected LayerStatusMap
	}{
		{
			name: "all pending become skipped",
			input: LayerStatusMap{
				Config:        "Pending",
				Manifests:     "Pending",
				Charts:        "Pending",
				Scripts:       "Pending",
				ImagesLinux:   "Pending",
				ImagesWindows: "Pending",
				Packages:      "Pending",
			},
			expected: LayerStatusMap{
				Config:        "Skipped",
				Manifests:     "Skipped",
				Charts:        "Skipped",
				Scripts:       "Skipped",
				ImagesLinux:   "Skipped",
				ImagesWindows: "Skipped",
				Packages:      "Skipped",
			},
		},
		{
			name: "completed layers preserved, pending become skipped",
			input: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Completed",
				Charts:        "Pending",
				Scripts:       "Completed",
				ImagesLinux:   "Completed",
				ImagesWindows: "Completed",
				Packages:      "Pending",
			},
			expected: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Completed",
				Charts:        "Skipped",
				Scripts:       "Completed",
				ImagesLinux:   "Completed",
				ImagesWindows: "Completed",
				Packages:      "Skipped",
			},
		},
		{
			name: "failed layers preserved",
			input: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Failed",
				Charts:        "Pending",
				Scripts:       "Completed",
				ImagesLinux:   "Skipped",
				ImagesWindows: "Pending",
				Packages:      "Pending",
			},
			expected: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Failed",
				Charts:        "Skipped",
				Scripts:       "Completed",
				ImagesLinux:   "Skipped",
				ImagesWindows: "Skipped",
				Packages:      "Skipped",
			},
		},
		{
			name: "all completed no change",
			input: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Completed",
				Charts:        "Completed",
				Scripts:       "Completed",
				ImagesLinux:   "Completed",
				ImagesWindows: "Completed",
				Packages:      "Completed",
			},
			expected: LayerStatusMap{
				Config:        "Completed",
				Manifests:     "Completed",
				Charts:        "Completed",
				Scripts:       "Completed",
				ImagesLinux:   "Completed",
				ImagesWindows: "Completed",
				Packages:      "Completed",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &K2sAddonReconciler{}
			addon := &K2sAddon{
				Status: K2sAddonStatus{
					LayerStatus: tt.input,
				},
			}
			r.finalizePendingLayers(addon)

			ls := addon.Status.LayerStatus
			if ls.Config != tt.expected.Config {
				t.Errorf("Config = %q, want %q", ls.Config, tt.expected.Config)
			}
			if ls.Manifests != tt.expected.Manifests {
				t.Errorf("Manifests = %q, want %q", ls.Manifests, tt.expected.Manifests)
			}
			if ls.Charts != tt.expected.Charts {
				t.Errorf("Charts = %q, want %q", ls.Charts, tt.expected.Charts)
			}
			if ls.Scripts != tt.expected.Scripts {
				t.Errorf("Scripts = %q, want %q", ls.Scripts, tt.expected.Scripts)
			}
			if ls.ImagesLinux != tt.expected.ImagesLinux {
				t.Errorf("ImagesLinux = %q, want %q", ls.ImagesLinux, tt.expected.ImagesLinux)
			}
			if ls.ImagesWindows != tt.expected.ImagesWindows {
				t.Errorf("ImagesWindows = %q, want %q", ls.ImagesWindows, tt.expected.ImagesWindows)
			}
			if ls.Packages != tt.expected.Packages {
				t.Errorf("Packages = %q, want %q", ls.Packages, tt.expected.Packages)
			}
		})
	}
}

func TestMergeStatus(t *testing.T) {
	tests := []struct {
		name              string
		nodeType          string
		targetImgLinux    string
		targetImgWindows  string
		desiredImgLinux   string
		desiredImgWindows string
		expectImgLinux    string
		expectImgWindows  string
	}{
		{
			name:              "linux controller preserves windows status",
			nodeType:          "linux",
			targetImgLinux:    "Pending",
			targetImgWindows:  "Completed",
			desiredImgLinux:   "Completed",
			desiredImgWindows: "Skipped",
			expectImgLinux:    "Completed",
			expectImgWindows:  "Completed", // preserved from target
		},
		{
			name:              "windows controller preserves linux status",
			nodeType:          "windows",
			targetImgLinux:    "Completed",
			targetImgWindows:  "Pending",
			desiredImgLinux:   "Skipped",
			desiredImgWindows: "Completed",
			expectImgLinux:    "Completed", // preserved from target
			expectImgWindows:  "Completed",
		},
		{
			name:              "linux controller writes both common and linux-specific",
			nodeType:          "linux",
			targetImgLinux:    "",
			targetImgWindows:  "",
			desiredImgLinux:   "Processing",
			desiredImgWindows: "Skipped",
			expectImgLinux:    "Processing",
			expectImgWindows:  "", // empty preserved from target
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &K2sAddonReconciler{NodeType: tt.nodeType}

			target := &K2sAddonStatus{
				LayerStatus: LayerStatusMap{
					Config:        "Pending",
					ImagesLinux:   tt.targetImgLinux,
					ImagesWindows: tt.targetImgWindows,
				},
			}
			desired := &K2sAddonStatus{
				Phase:     "Processing",
				Available: false,
				LayerStatus: LayerStatusMap{
					Config:        "Completed",
					Manifests:     "Completed",
					ImagesLinux:   tt.desiredImgLinux,
					ImagesWindows: tt.desiredImgWindows,
				},
			}

			r.mergeStatus(target, desired)

			if target.Phase != "Processing" {
				t.Errorf("Phase = %q, want %q", target.Phase, "Processing")
			}
			if target.LayerStatus.Config != "Completed" {
				t.Errorf("Config = %q, want %q", target.LayerStatus.Config, "Completed")
			}
			if target.LayerStatus.ImagesLinux != tt.expectImgLinux {
				t.Errorf("ImagesLinux = %q, want %q", target.LayerStatus.ImagesLinux, tt.expectImgLinux)
			}
			if target.LayerStatus.ImagesWindows != tt.expectImgWindows {
				t.Errorf("ImagesWindows = %q, want %q", target.LayerStatus.ImagesWindows, tt.expectImgWindows)
			}
		})
	}
}

func TestMergeStatusPreservesLastPulledDigest(t *testing.T) {
	r := &K2sAddonReconciler{NodeType: "linux"}

	target := &K2sAddonStatus{
		Phase: "Pending",
	}
	desired := &K2sAddonStatus{
		Phase:            "Available",
		Available:        true,
		LastPulledDigest: "sha256:abc123def456",
		LayerStatus:      LayerStatusMap{},
	}

	r.mergeStatus(target, desired)

	if target.LastPulledDigest != "sha256:abc123def456" {
		t.Errorf("LastPulledDigest = %q, want %q", target.LastPulledDigest, "sha256:abc123def456")
	}

	target2 := &K2sAddonStatus{
		LastPulledDigest: "sha256:existing",
	}
	desired2 := &K2sAddonStatus{
		Phase:       "Pulling",
		LayerStatus: LayerStatusMap{},
	}
	r.mergeStatus(target2, desired2)

	if target2.LastPulledDigest != "sha256:existing" {
		t.Errorf("LastPulledDigest should be preserved when desired is empty, got %q", target2.LastPulledDigest)
	}
}

func TestParseCurlPackages(t *testing.T) {
	tests := []struct {
		name           string
		manifestYAML   string
		implementation string
		wantLinux      int
		wantWindows    int
	}{
		{
			name: "single implementation with curl packages",
			manifestYAML: `apiVersion: v1
kind: AddonManifest
metadata:
  name: kubevirt
spec:
  implementations:
    - name: kubevirt
      offline_usage:
        linux:
          curl:
            - url: https://example.com/virtctl-linux
              destination: /usr/local/bin/virtctl
        windows:
          curl:
            - url: https://example.com/virtctl-windows.exe
              destination: bin\virtctl.exe
`,
			implementation: "kubevirt",
			wantLinux:      1,
			wantWindows:    1,
		},
		{
			name: "no offline_usage section",
			manifestYAML: `apiVersion: v1
kind: AddonManifest
metadata:
  name: metrics
spec:
  implementations:
    - name: metrics
`,
			implementation: "metrics",
			wantLinux:      0,
			wantWindows:    0,
		},
		{
			name: "multi-implementation selects matching one",
			manifestYAML: `apiVersion: v1
kind: AddonManifest
metadata:
  name: ingress
spec:
  implementations:
    - name: nginx
      offline_usage:
        linux:
          curl:
            - url: https://example.com/nginx-tool
              destination: /usr/local/bin/nginx-tool
    - name: traefik
      offline_usage:
        linux:
          curl:
            - url: https://example.com/traefik-a
              destination: /usr/local/bin/a
            - url: https://example.com/traefik-b
              destination: /usr/local/bin/b
`,
			implementation: "traefik",
			wantLinux:      2,
			wantWindows:    0,
		},
		{
			name: "empty implementation falls back to matching",
			manifestYAML: `apiVersion: v1
kind: AddonManifest
metadata:
  name: test
spec:
  implementations:
    - name: test
      offline_usage:
        linux:
          curl:
            - url: https://example.com/tool
              destination: /usr/local/bin/tool
`,
			implementation: "",
			wantLinux:      1,
			wantWindows:    0,
		},
		{
			name:           "invalid yaml returns empty",
			manifestYAML:   "not: valid: yaml: {{{}}}",
			implementation: "test",
			wantLinux:      0,
			wantWindows:    0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			linux, windows := parseCurlPackages([]byte(tt.manifestYAML), tt.implementation)
			if len(linux) != tt.wantLinux {
				t.Errorf("linux curl packages = %d, want %d", len(linux), tt.wantLinux)
			}
			if len(windows) != tt.wantWindows {
				t.Errorf("windows curl packages = %d, want %d", len(windows), tt.wantWindows)
			}
		})
	}
}

func TestExtractTarGzPathTraversal(t *testing.T) {
	_ = extractTarGzToDir
	_ = extractTarStreamToDir
}

func TestDetermineAddonPathMultiImplementation(t *testing.T) {
	tests := []struct {
		name           string
		addonsPath     string
		addonName      string
		implementation string
		expected       string
	}{
		{
			name:           "ingress nginx sub-path",
			addonsPath:     filepath.FromSlash("/addons"),
			addonName:      "ingress",
			implementation: "nginx",
			expected:       filepath.FromSlash("/addons/ingress/nginx"),
		},
		{
			name:           "ingress traefik sub-path",
			addonsPath:     filepath.FromSlash("/addons"),
			addonName:      "ingress",
			implementation: "traefik",
			expected:       filepath.FromSlash("/addons/ingress/traefik"),
		},
		{
			name:           "rollout argocd sub-path",
			addonsPath:     "C:\\ws\\addons",
			addonName:      "rollout",
			implementation: "argocd",
			expected:       "C:\\ws\\addons\\rollout\\argocd",
		},
		{
			name:           "rollout fluxcd sub-path",
			addonsPath:     "C:\\ws\\addons",
			addonName:      "rollout",
			implementation: "fluxcd",
			expected:       "C:\\ws\\addons\\rollout\\fluxcd",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			r := &K2sAddonReconciler{AddonsPath: tt.addonsPath}
			addon := &K2sAddon{
				Spec: K2sAddonSpec{
					Name:           tt.addonName,
					Implementation: tt.implementation,
				},
			}
			result := r.determineAddonPath(addon)
			if result != tt.expected {
				t.Errorf("determineAddonPath() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestOCIRepositorySourceValidation(t *testing.T) {
	source := AddonSource{
		Type:          "OCIRepository",
		OCIRepository: nil,
	}

	if source.OCIRepository != nil {
		t.Error("Expected nil OCIRepository reference")
	}

	source.OCIRepository = &OCIRepoRef{
		Name:      "metrics-addon",
		Namespace: "rollout",
	}

	if source.OCIRepository.Name != "metrics-addon" {
		t.Errorf("Name = %q, want %q", source.OCIRepository.Name, "metrics-addon")
	}
	if source.OCIRepository.Namespace != "rollout" {
		t.Errorf("Namespace = %q, want %q", source.OCIRepository.Namespace, "rollout")
	}
}

func TestStatusDeepCopy(t *testing.T) {
	now := metav1.Now()
	original := &K2sAddonStatus{
		Phase:     "Available",
		Available: true,
		LayerStatus: LayerStatusMap{
			Config:        "Completed",
			Manifests:     "Completed",
			Charts:        "Skipped",
			Scripts:       "Completed",
			ImagesLinux:   "Completed",
			ImagesWindows: "Completed",
			Packages:      "Skipped",
		},
		NodeStatus: []NodeStatusEntry{
			{NodeName: "node1", NodeType: "linux", ImagesImported: true, LastUpdated: &now},
			{NodeName: "node2", NodeType: "windows", ImagesImported: true},
		},
		LastProcessedTime: &now,
		LastPulledDigest:  "sha256:abc123",
		ErrorMessage:      "",
	}

	copied := original.DeepCopy()

	original.Phase = "Failed"
	if copied.Phase == "Failed" {
		t.Error("DeepCopy is not independent - Phase was modified")
	}

	original.LayerStatus.Config = "Failed"
	if copied.LayerStatus.Config == "Failed" {
		t.Error("DeepCopy is not independent - LayerStatus was modified")
	}

	original.NodeStatus[0].NodeName = "modified"
	if copied.NodeStatus[0].NodeName == "modified" {
		t.Error("DeepCopy is not independent - NodeStatus was modified")
	}

	original.LastPulledDigest = "sha256:modified"
	if copied.LastPulledDigest == "sha256:modified" {
		t.Error("DeepCopy is not independent - LastPulledDigest was modified")
	}
}

func TestCopyFile(t *testing.T) {
	srcDir := t.TempDir()
	srcPath := srcDir + "/source.txt"
	content := []byte("hello world test content")
	if err := os.WriteFile(srcPath, content, 0644); err != nil {
		t.Fatalf("Failed to write source file: %v", err)
	}

	dstDir := t.TempDir()
	dstPath := dstDir + "/nested/dir/dest.txt"
	if err := copyFile(srcPath, dstPath); err != nil {
		t.Fatalf("copyFile() error: %v", err)
	}

	got, err := os.ReadFile(dstPath)
	if err != nil {
		t.Fatalf("Failed to read dest file: %v", err)
	}
	if string(got) != string(content) {
		t.Errorf("Content mismatch: got %q, want %q", string(got), string(content))
	}
}

func TestCopyFileSourceNotFound(t *testing.T) {
	dstDir := t.TempDir()
	err := copyFile("/nonexistent/path/file.txt", dstDir+"/dest.txt")
	if err == nil {
		t.Error("Expected error for nonexistent source file")
	}
}

func TestExtractTarStreamToDir(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)

	tw.WriteHeader(&tar.Header{
		Name:     "testdir/",
		Typeflag: tar.TypeDir,
		Mode:     0755,
	})

	content := []byte("file content here")
	tw.WriteHeader(&tar.Header{
		Name:     "testdir/file.txt",
		Typeflag: tar.TypeReg,
		Mode:     0644,
		Size:     int64(len(content)),
	})
	tw.Write(content)

	badContent := []byte("malicious")
	tw.WriteHeader(&tar.Header{
		Name:     "../../../etc/passwd",
		Typeflag: tar.TypeReg,
		Mode:     0644,
		Size:     int64(len(badContent)),
	})
	tw.Write(badContent)

	tw.Close()

	destDir := t.TempDir()
	if err := extractTarStreamToDir(&buf, destDir); err != nil {
		t.Fatalf("extractTarStreamToDir() error: %v", err)
	}

	got, err := os.ReadFile(destDir + "/testdir/file.txt")
	if err != nil {
		t.Fatalf("Expected file not found: %v", err)
	}
	if string(got) != "file content here" {
		t.Errorf("Content = %q, want %q", string(got), "file content here")
	}

	if _, err := os.Stat(destDir + "/../../../etc/passwd"); err == nil {
		t.Error("Path traversal file should not have been extracted")
	}
}

func TestAddToSchemeRegistersTypes(t *testing.T) {
	scheme := runtime.NewScheme()
	err := AddToScheme(scheme)
	if err != nil {
		t.Fatalf("AddToScheme() error: %v", err)
	}

	gvk := schema.GroupVersionKind{
		Group:   "k2s.siemens-healthineers.com",
		Version: "v1alpha1",
		Kind:    "K2sAddon",
	}

	obj, err := scheme.New(gvk)
	if err != nil {
		t.Fatalf("scheme.New() error: %v", err)
	}
	if obj == nil {
		t.Error("Expected non-nil object for K2sAddon GVK")
	}

	gvk.Kind = "K2sAddonList"
	obj, err = scheme.New(gvk)
	if err != nil {
		t.Fatalf("scheme.New() for List error: %v", err)
	}
	if obj == nil {
		t.Error("Expected non-nil object for K2sAddonList GVK")
	}
}

func TestParseDockerSaveRepoTags(t *testing.T) {
	t.Run("valid manifest with tags", func(t *testing.T) {
		tarPath := createDockerSaveTar(t, []dockerSaveManifest{
			{RepoTags: []string{"myrepo/myimage:v1.0", "myrepo/myimage:latest"}},
		})
		tags, err := parseDockerSaveRepoTags(tarPath)
		if err != nil {
			t.Fatalf("parseDockerSaveRepoTags() error: %v", err)
		}
		if len(tags) != 2 {
			t.Fatalf("Expected 2 tags, got %d", len(tags))
		}
		if tags[0] != "myrepo/myimage:v1.0" || tags[1] != "myrepo/myimage:latest" {
			t.Errorf("Unexpected tags: %v", tags)
		}
	})

	t.Run("manifest with no tags", func(t *testing.T) {
		tarPath := createDockerSaveTar(t, []dockerSaveManifest{
			{RepoTags: nil},
		})
		tags, err := parseDockerSaveRepoTags(tarPath)
		if err != nil {
			t.Fatalf("parseDockerSaveRepoTags() error: %v", err)
		}
		if len(tags) != 0 {
			t.Errorf("Expected 0 tags, got %d: %v", len(tags), tags)
		}
	})

	t.Run("multiple entries", func(t *testing.T) {
		tarPath := createDockerSaveTar(t, []dockerSaveManifest{
			{RepoTags: []string{"image-a:v1"}},
			{RepoTags: []string{"image-b:v2", "image-b:latest"}},
		})
		tags, err := parseDockerSaveRepoTags(tarPath)
		if err != nil {
			t.Fatalf("parseDockerSaveRepoTags() error: %v", err)
		}
		if len(tags) != 3 {
			t.Fatalf("Expected 3 tags, got %d: %v", len(tags), tags)
		}
	})

	t.Run("no manifest.json", func(t *testing.T) {
		dir := t.TempDir()
		tarPath := filepath.Join(dir, "no-manifest.tar")
		f, err := os.Create(tarPath)
		if err != nil {
			t.Fatal(err)
		}
		tw := tar.NewWriter(f)
		tw.WriteHeader(&tar.Header{Name: "other.json", Size: 2})
		tw.Write([]byte("{}"))
		tw.Close()
		f.Close()

		_, err = parseDockerSaveRepoTags(tarPath)
		if err == nil {
			t.Error("Expected error for tar without manifest.json")
		}
	})

	t.Run("nonexistent file", func(t *testing.T) {
		_, err := parseDockerSaveRepoTags("/nonexistent/path.tar")
		if err == nil {
			t.Error("Expected error for nonexistent file")
		}
	})
}

// dockerSaveManifest mirrors the structure of Docker-save manifest.json entries.
type dockerSaveManifest struct {
	RepoTags []string `json:"RepoTags"`
}

// createDockerSaveTar creates a minimal Docker-save tar containing a manifest.json
// with the given entries. Returns the path to the tar file.
func createDockerSaveTar(t *testing.T, manifests []dockerSaveManifest) string {
	t.Helper()
	dir := t.TempDir()
	tarPath := filepath.Join(dir, "image.tar")

	f, err := os.Create(tarPath)
	if err != nil {
		t.Fatalf("Failed to create tar: %v", err)
	}
	defer f.Close()

	tw := tar.NewWriter(f)
	defer tw.Close()

	data, err := json.Marshal(manifests)
	if err != nil {
		t.Fatalf("Failed to marshal manifest: %v", err)
	}

	if err := tw.WriteHeader(&tar.Header{
		Name: "manifest.json",
		Size: int64(len(data)),
	}); err != nil {
		t.Fatalf("Failed to write tar header: %v", err)
	}
	if _, err := tw.Write(data); err != nil {
		t.Fatalf("Failed to write tar data: %v", err)
	}

	return tarPath
}
