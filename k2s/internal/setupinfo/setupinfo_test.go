// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo_test

import (
	"encoding/json"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
)

func TestSetupinfo(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setupinfo Integration Tests", Label("integration", "ci", "setupinfo"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("setupinfo pkg", func() {
	Describe("LoadConfig", func() {
		Context("config file does not exist", func() {
			It("returns system-not-installed error", func() {
				config, err := setupinfo.LoadConfig(GinkgoT().TempDir())

				Expect(config).To(BeNil())
				Expect(err).To(MatchError(setupinfo.ErrSystemNotInstalled))
			})
		})

		Context("config file exists", func() {
			var dir string
			var inputConfig *setupinfo.Config

			BeforeEach(func() {
				inputConfig = &setupinfo.Config{
					SetupName:        "test-name",
					Registries:       []string{"r1", "r2"},
					LoggedInRegistry: "r2",
					LinuxOnly:        true,
					Version:          "test-version",
				}
				inputData, err := json.Marshal(inputConfig)
				Expect(err).ToNot(HaveOccurred())

				dir = GinkgoT().TempDir()
				configPath := filepath.Join(dir, "setup.json")

				GinkgoWriter.Println("Writing test data to <", configPath, ">")

				file, err := os.OpenFile(configPath, os.O_CREATE, os.ModeAppend)
				Expect(err).ToNot(HaveOccurred())

				_, err = file.Write(inputData)
				Expect(err).ToNot(HaveOccurred())
				Expect(file.Close()).To(Succeed())
			})

			It("returns config data", func() {
				config, err := setupinfo.LoadConfig(dir)

				Expect(err).ToNot(HaveOccurred())
				Expect(config.LinuxOnly).To(Equal(inputConfig.LinuxOnly))
				Expect(config.LoggedInRegistry).To(Equal(inputConfig.LoggedInRegistry))
				Expect(config.Registries).To(Equal(inputConfig.Registries))
				Expect(config.SetupName).To(Equal(inputConfig.SetupName))
				Expect(config.Version).To(Equal(inputConfig.Version))
			})
		})
	})
})
