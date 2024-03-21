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
	Describe("LoadConfig", Ordered, func() {
		var actual *config.Config

		BeforeAll(func() {
			currentDir, err := host.ExecutableDir()
			installDir := filepath.Join(currentDir, "..\\..\\..")

			Expect(err).ToNot(HaveOccurred())

			GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

			actual, err = config.LoadConfig(installDir)

			Expect(err).ToNot(HaveOccurred())
		})

		It("kube config path is cleaned and absolute", func() {
			GinkgoWriter.Println("Setup config dir: <", actual.Host.KubeConfigDir, ">")

			Expect(filepath.IsAbs(actual.Host.KubeConfigDir)).To(BeTrue())
			Expect(actual.Host.KubeConfigDir).ToNot(ContainSubstring("/"))
		})

		It("nodes config contains Windows and Linux nodes", func() {
			Expect(actual.Nodes).To(ConsistOf(
				HaveField("OsType", config.OsTypeLinux),
				HaveField("OsType", config.OsTypeWindows),
			))
		})
	})
})
