// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package corruptedstate

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
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

	Context("default output", func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "status")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Context("extended output", func() {
		It("prints system-in-corrupted-state message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "status", "-o", "wide")

			Expect(output).To(ContainSubstring("corrupted state"))
		})
	})

	Context("JSON output", func() {
		var status status.PrintStatus

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "status", "-o", "json")

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
