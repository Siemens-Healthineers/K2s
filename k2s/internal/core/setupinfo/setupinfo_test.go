// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
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
	Describe("ConfigPath", func() {
		It("returns full config file path", func() {
			const dir = "my-dir"

			actual := setupinfo.ConfigPath(dir)

			Expect(actual).To(Equal("my-dir\\setup.json"))
		})
	})

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
					SetupName:  "test-name",
					Registries: []string{"r1", "r2"},
					LinuxOnly:  true,
					Version:    "test-version",
				}

				Expect(setupinfo.WriteConfig(dir, inputConfig)).ToNot(HaveOccurred())
			})

			It("returns config data", func() {
				config, err := setupinfo.ReadConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.LinuxOnly).To(Equal(inputConfig.LinuxOnly))
				Expect(config.Registries).To(Equal(inputConfig.Registries))
				Expect(config.SetupName).To(Equal(inputConfig.SetupName))
				Expect(config.Version).To(Equal(inputConfig.Version))
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

				Expect(setupinfo.WriteConfig(dir, inputConfig)).ToNot(HaveOccurred())
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
	})

	Describe("WriteConfig", func() {
		When("config file does not exist", func() {
			var dir string
			var randomName setupinfo.SetupName

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				randomName = setupinfo.SetupName(fmt.Sprintf("%v", GinkgoT().RandomSeed()))
			})

			It("new config file gets created", func() {
				config := &setupinfo.Config{SetupName: randomName}

				err := setupinfo.WriteConfig(dir, config)
				Expect(err).ToNot(HaveOccurred())

				readConfig, err := setupinfo.ReadConfig(dir)
				Expect(err).ToNot(HaveOccurred())

				Expect(readConfig.SetupName).To(Equal(randomName))
			})
		})

		When("config file exists", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()

				config := &setupinfo.Config{SetupName: "initial-name"}

				Expect(setupinfo.WriteConfig(dir, config)).ToNot(HaveOccurred())
			})

			It("config file gets overwritten", func() {
				config := &setupinfo.Config{SetupName: "new-name"}

				err := setupinfo.WriteConfig(dir, config)
				Expect(err).ToNot(HaveOccurred())

				readConfig, err := setupinfo.ReadConfig(dir)
				Expect(err).ToNot(HaveOccurred())

				Expect(string(readConfig.SetupName)).To(Equal("new-name"))
			})
		})
	})

	Describe("DeleteConfig", func() {
		When("config file does not exist", func() {
			It("returns file-non-existent error", func() {
				err := setupinfo.DeleteConfig(GinkgoT().TempDir())

				Expect(err).To(MatchError(fs.ErrNotExist))
			})
		})

		When("config file exists", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				config := &setupinfo.Config{SetupName: "to-be-deleted"}

				Expect(setupinfo.WriteConfig(dir, config)).ToNot(HaveOccurred())
			})

			It("deletes the file", func() {
				err := setupinfo.DeleteConfig(dir)

				Expect(err).ToNot(HaveOccurred())

				_, err = os.Stat(filepath.Join(dir, setupinfo.ConfigFileName))

				Expect(err).To(MatchError(fs.ErrNotExist))
			})
		})
	})
})
