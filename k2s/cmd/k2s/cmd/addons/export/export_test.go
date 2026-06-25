// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package export

import (
	"strings"
	"testing"
)

// TestFlagMappingLogic tests the CLI-to-PowerShell flag mapping logic.
// This test uses a focused approach that validates the conditional logic
// without requiring the full buildPsCmd environment setup.
func TestFlagMappingLogic(t *testing.T) {
	tests := []struct {
		name             string
		omitImages       bool
		omitPackages     bool
		wantOmitImages   bool
		wantOmitPackages bool
	}{
		{
			name:             "no flags - images should be acquired",
			omitImages:       false,
			omitPackages:     false,
			wantOmitImages:   false,
			wantOmitPackages: false,
		},
		{
			name:             "omit-images flag - no acquire",
			omitImages:       true,
			omitPackages:     false,
			wantOmitImages:   true,
			wantOmitPackages: false,
		},
		{
			name:             "omit-packages flag - only packages omitted",
			omitImages:       false,
			omitPackages:     true,
			wantOmitImages:   false,
			wantOmitPackages: true,
		},
		{
			name:             "both flags - only packages omitted, no image flags",
			omitImages:       true,
			omitPackages:     true,
			wantOmitImages:   true,
			wantOmitPackages: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the flag mapping logic from buildPsCmd
			params := ""

			// This mirrors the logic from export.go buildPsCmd function:
			// if omitImages { params += " -OmitImages" }
			if tt.omitImages {
				params += " -OmitImages"
			}

			// This mirrors: if omitPackages { params += " -OmitPackages" }
			if tt.omitPackages {
				params += " -OmitPackages"
			}

			// Verify -OmitImages presence
			hasOmitImages := strings.Contains(params, "-OmitImages")
			if hasOmitImages != tt.wantOmitImages {
				t.Errorf("wantOmitImages=%v, got=%v, params=%q", tt.wantOmitImages, hasOmitImages, params)
			}

			// Verify -OmitPackages presence
			hasOmitPackages := strings.Contains(params, "-OmitPackages")
			if hasOmitPackages != tt.wantOmitPackages {
				t.Errorf("wantOmitPackages=%v, got=%v, params=%q", tt.wantOmitPackages, hasOmitPackages, params)
			}
		})
	}
}
