// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	kos "github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestNode(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node CLI Commands Acceptance Tests", Label("cli", "node", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node", Ordered, func() {
	var configPath string

	// TODO: extract 'system-in-corrupted-state' to DSL for re-use
	BeforeEach(func() {
		inputConfig := &setupinfo.Config{
			SetupName:  "k2s",
			Registries: []string{"r1", "r2"},
			LinuxOnly:  true,
			Version:    "test-version",
			Corrupted:  true,
		}
		inputData, err := json.Marshal(inputConfig)
		Expect(err).ToNot(HaveOccurred())

		currentDir, err := kos.ExecutableDir()
		Expect(err).ToNot(HaveOccurred())
		installDir := filepath.Join(currentDir, "..\\..\\..\\..\\..\\..\\..\\..")

		GinkgoWriter.Println("Current test dir: <", currentDir, ">, install dir: <", installDir, ">")

		config, err := config.LoadConfig(installDir)
		Expect(err).ToNot(HaveOccurred())

		GinkgoWriter.Println("Creating <", config.Host().K2sConfigDir(), ">..")

		Expect(os.MkdirAll(config.Host().K2sConfigDir(), os.ModePerm)).To(Succeed())

		configPath = filepath.Join(config.Host().K2sConfigDir(), "setup.json")

		GinkgoWriter.Println("Writing test data to <", configPath, ">..")

		Expect(os.WriteFile(configPath, inputData, os.ModePerm)).To(Succeed())

		DeferCleanup(func() {
			GinkgoWriter.Println("Deleting <", config.Host().K2sConfigDir(), ">..")

			Expect(os.RemoveAll(config.Host().K2sConfigDir())).To(Succeed())
		})
	})

	Describe("copy", Label("copy"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "copy", "--ip-addr", "", "-s", "", "-t", "", "-u", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("exec", Label("exec"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "exec", "-i", "", "-u", "", "-c", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Describe("connect", Label("connect"), func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "node", "connect", "-i", "", "-u", "")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})
})
