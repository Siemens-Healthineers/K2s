// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package config_test

import (
	"encoding/json"
	"errors"
	"os"
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
		When("config file does not exist", func() {
			It("returns not-exist error", func() {
				config, err := config.LoadConfig(GinkgoT().TempDir())

				Expect(config).To(BeNil())
				Expect(err).To(MatchError(os.ErrNotExist))
			})
		})

		When("config file is corrupted", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				subDir := filepath.Join(dir, "cfg")

				Expect(os.MkdirAll(subDir, os.ModePerm)).To(Succeed())

				configPath := filepath.Join(subDir, "config.json")

				GinkgoWriter.Println("Writing corrupted test file to <", configPath, ">")

				file, err := os.OpenFile(configPath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(" "))
				Expect(err).ToNot(HaveOccurred())
				Expect(file.Close()).To(Succeed())
			})

			It("returns JSON syntax error", func() {
				config, err := config.LoadConfig(dir)

				Expect(config).To(BeNil())

				var syntaxError *json.SyntaxError
				Expect(errors.As(err, &syntaxError)).To(BeTrue())
			})
		})

		When("config file exists", func() {
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
})
