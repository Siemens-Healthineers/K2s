// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"

	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	kos "github.com/siemens-healthineers/k2s/internal/os"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status", Ordered, func() {
	var configPath string

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

	Context("default output", func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "status")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Context("extended output", func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "status", "-o", "wide")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Context("JSON output", func() {
		var status status.PrintStatus

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "status", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains system-in-corrupted-state info", func() {
			Expect(*status.Error).To(Equal(setupinfo.ErrSystemInCorruptedState.Error()))
		})

		It("does not contain any other info", func() {
			Expect(status.SetupInfo).To(BeNil())
			Expect(status.RunningState).To(BeNil())
			Expect(status.Nodes).To(BeNil())
			Expect(status.Pods).To(BeNil())
			Expect(status.K8sVersionInfo).To(BeNil())
		})
	})
})
