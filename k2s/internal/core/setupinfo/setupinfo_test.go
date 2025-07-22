// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"encoding/json"
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
)

func TestSetupinfo(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setupinfo Integration Tests", Label("integration", "ci", "setupinfo"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("setupinfo pkg", func() {
	Describe("ReadConfig", func() {
		When("config file does not exist", func() {
			It("returns system-not-installed error", func() {
				config, err := setupinfo.ReadConfig(GinkgoT().TempDir())

				Expect(config).To(BeNil())
				Expect(err).To(MatchError(setupinfo.ErrSystemNotInstalled))
			})
		})

		When("config file is corrupted", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				configPath := filepath.Join(dir, setupinfo.ConfigFileName)

				GinkgoWriter.Println("Writing corrupted test file to <", configPath, ">")

				file, err := os.OpenFile(configPath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write([]byte(" "))
				Expect(err).ToNot(HaveOccurred())
				Expect(file.Close()).To(Succeed())
			})

			It("returns JSON syntax error", func() {
				config, err := setupinfo.ReadConfig(dir)

				Expect(config).To(BeNil())

				var syntaxError *json.SyntaxError
				Expect(errors.As(err, &syntaxError)).To(BeTrue())
			})
		})

		When("config file exists", func() {
			var dir string
			var inputConfig *setupinfo.Config

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = &setupinfo.Config{
					SetupName:                "test-name",
					Registries:               []string{"r1", "r2"},
					LinuxOnly:                true,
					Version:                  "test-version",
					ClusterName:              "my-cluster",
					ControlPlaneNodeHostname: "my-host",
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, setupinfo.ConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config data", func() {
				config, err := setupinfo.ReadConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.LinuxOnly).To(Equal(inputConfig.LinuxOnly))
				Expect(config.Registries).To(Equal(inputConfig.Registries))
				Expect(config.SetupName).To(Equal(inputConfig.SetupName))
				Expect(config.Version).To(Equal(inputConfig.Version))
				Expect(config.ClusterName).To(Equal(inputConfig.ClusterName))
				Expect(config.ControlPlaneNodeHostname).To(Equal(inputConfig.ControlPlaneNodeHostname))
			})
		})

		When("config file has entry 'Corrupted' (errors during installation)", func() {
			var dir string
			var inputConfig *setupinfo.Config

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = &setupinfo.Config{
					SetupName:  "test-name",
					Registries: []string{"r1", "r2"},
					LinuxOnly:  true,
					Version:    "test-version",
					Corrupted:  true,
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, setupinfo.ConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config data and system-in-corrupted-state error", func() {
				config, err := setupinfo.ReadConfig(dir)

				Expect(err).To(Equal(setupinfo.ErrSystemInCorruptedState))
				Expect(config.LinuxOnly).To(Equal(inputConfig.LinuxOnly))
				Expect(config.Registries).To(Equal(inputConfig.Registries))
				Expect(config.SetupName).To(Equal(inputConfig.SetupName))
				Expect(config.Version).To(Equal(inputConfig.Version))
				Expect(config.Corrupted).To(Equal(inputConfig.Corrupted))
			})
		})

		When("config file misses cluster name entry", func() {
			var dir string
			var inputConfig *setupinfo.Config

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				inputConfig = &setupinfo.Config{
					SetupName:                "test-name",
					Registries:               []string{"r1", "r2"},
					LinuxOnly:                true,
					Version:                  "test-version",
					ControlPlaneNodeHostname: "my-host",
				}

				blob, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())
				Expect(os.WriteFile(filepath.Join(dir, setupinfo.ConfigFileName), blob, os.ModePerm)).To(Succeed())
			})

			It("returns config with legacy cluster name", func() {
				config, err := setupinfo.ReadConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.LinuxOnly).To(Equal(inputConfig.LinuxOnly))
				Expect(config.Registries).To(Equal(inputConfig.Registries))
				Expect(config.SetupName).To(Equal(inputConfig.SetupName))
				Expect(config.Version).To(Equal(inputConfig.Version))
				Expect(config.ClusterName).To(Equal("kubernetes"))
				Expect(config.ControlPlaneNodeHostname).To(Equal(inputConfig.ControlPlaneNodeHostname))
			})
		})
	})

	Describe("MarkSetupAsCorrupted", func() {
		When("config file does not exist", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
			})

			It("creates new config file with corrupted state marker", func() {
				Expect(setupinfo.MarkSetupAsCorrupted(dir)).ToNot(HaveOccurred())

				configBlob, err := os.ReadFile(filepath.Join(dir, setupinfo.ConfigFileName))
				Expect(err).ToNot(HaveOccurred())

				var config map[string]any
				Expect(json.Unmarshal(configBlob, &config)).ToNot(HaveOccurred())

				Expect(config).To(HaveLen(1))
				Expect(config["Corrupted"]).To(BeTrue())
			})
		})

		When("config file exists", func() {
			var dir string
			var configPath string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				config := map[string]any{"prop1": "val1", "prop2": "val2", "prop3": 123.45}

				configBlob, err := json.Marshal(config)
				Expect(err).ToNot(HaveOccurred())

				configPath = filepath.Join(dir, setupinfo.ConfigFileName)

				Expect(os.WriteFile(configPath, configBlob, os.ModePerm)).To(Succeed())
			})

			It("marks existing config as corrupted without modifying the other values", func() {
				Expect(setupinfo.MarkSetupAsCorrupted(dir)).ToNot(HaveOccurred())

				configBlob, err := os.ReadFile(configPath)
				Expect(err).ToNot(HaveOccurred())

				var config map[string]any
				Expect(json.Unmarshal(configBlob, &config)).ToNot(HaveOccurred())

				Expect(config).To(HaveLen(4))
				Expect(config["Corrupted"]).To(BeTrue())
				Expect(config["prop1"]).To(Equal("val1"))
				Expect(config["prop2"]).To(Equal("val2"))
				Expect(config["prop3"]).To(Equal(123.45))
			})
		})
	})
})
