// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package config_test

import (
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
)

func TestConfig(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "config Integration Tests", Label("integration", "ci", "config"))
}

var _ = Describe("config pkg", func() {
	Describe("LoadSetupConfigDir", func() {
		It("loads the setup config path as absolute dir", func() {
			currentDir, err := host.ExecutableDir()
			installDir := filepath.Join(currentDir, "..\\..\\..")

			Expect(err).ToNot(HaveOccurred())

			GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

			dir, err := config.LoadSetupConfigDir(installDir)

			GinkgoWriter.Println("Setup config dir: <", dir, ">")

			Expect(err).ToNot(HaveOccurred())
			Expect(filepath.IsAbs(dir)).To(BeTrue())
		})
	})
})
