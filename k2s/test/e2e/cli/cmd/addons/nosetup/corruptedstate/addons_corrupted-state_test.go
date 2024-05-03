// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/internal/addons"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite
var allAddons addons.Addons

func TestAddons(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Commands Acceptance Tests", Label("cli", "acceptance", "no-setup", "corrupted-state", "addons"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	allAddons = suite.AddonsAdditionalInfo().AllAddons()
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", Ordered, func() {
	var configPath string

	BeforeEach(func() {
		inputConfig := &setupinfo.Config{
			SetupName:        "k2s",
			Registries:       []string{"r1", "r2"},
			LoggedInRegistry: "r2",
			LinuxOnly:        true,
			Version:          "test-version",
			Corrupted:        true,
		}
		inputData, err := json.Marshal(inputConfig)
		Expect(err).ToNot(HaveOccurred())

		currentDir, err := host.ExecutableDir()
		Expect(err).ToNot(HaveOccurred())
		installDir := filepath.Join(currentDir, "..\\..\\..\\..\\..\\..\\..\\..")

		GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

		config, err := config.LoadConfig(installDir)
		Expect(err).ToNot(HaveOccurred())
		configPath = filepath.Join(config.Host.KubeConfigDir, "setup.json")

		GinkgoWriter.Println("Writing test data to <", configPath, ">")

		file, err := os.OpenFile(configPath, os.O_CREATE, os.ModePerm)
		Expect(err).ToNot(HaveOccurred())

		_, err = file.Write(inputData)
		Expect(err).ToNot(HaveOccurred())
		Expect(file.Close()).To(Succeed())
	})

	AfterAll(func() {
		_, err := os.Stat(configPath)
		if err == nil {
			GinkgoWriter.Println("Deleting <", configPath, ">..")
			Expect(os.Remove(configPath)).To(Succeed())
		}
	})

	Describe("ls", Ordered, func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "ls")
		})

		It("prints system-in-corrupted-state message", func() {
			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name)

					Expect(output).To(ContainSubstring("corrupted state"))
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-in-corrupted-state info and name and exits with non-zero", func(ctx context.Context) {
				for _, addon := range allAddons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "status", addon.Metadata.Name, "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Enabled).To(BeNil())
					Expect(status.Name).To(Equal(addon.Metadata.Name))
					Expect(*status.Error).To(Equal(setupinfo.ErrSystemInCorruptedState.Error()))
					Expect(status.Props).To(BeEmpty())
				}
			})
		})
	})

	Describe("disable", func() {
		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons disable for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("corrupted state"))
			}
		})
	})

	Describe("enable", func() {
		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons enable for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("corrupted state"))
			}
		})
	})

	Describe("export", func() {
		It("prints system-in-corrupted-state message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons export for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", addon.Metadata.Name, "-d", "test-dir")

				Expect(output).To(ContainSubstring("corrupted state"))
			}
		})

		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "export", "-d", "test-dir")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("import", func() {
		It("prints system-in-corrupted-state message for each addon and exits with non-zero", func(ctx context.Context) {
			for _, addon := range allAddons {
				GinkgoWriter.Println("Calling addons import for", addon.Metadata.Name)

				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", addon.Metadata.Name, "-z", "test-dir")

				Expect(output).To(ContainSubstring("corrupted state"))
			}
		})

		It("prints system-in-corrupted-state message for all addons and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "import", "-z", "test-dir")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})
})
