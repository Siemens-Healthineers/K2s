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

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests", Label("cli", "system", "scp", "ssh", "m", "w", "upgrade", "package", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system", Ordered, func() {
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

	DescribeTable("print system-in-corrupted-state message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, args...)

			Expect(output).To(ContainSubstring("corrupted state"))
		},

		Entry("scp m", "system", "scp", "m", "a1", "a2"),
		Entry("scp w", "system", "scp", "w", "a1", "a2"),
		Entry("ssh m connect", "system", "ssh", "m"),
		Entry("ssh m cmd", "system", "ssh", "m", "--", "echo yes"),
		Entry("ssh w connect", "system", "ssh", "w"),
		Entry("ssh w cmd", "system", "ssh", "w", "--", "echo yes"),
		Entry("upgrade", "system", "upgrade"),
		Entry("upgrade", "system", "reset", "network"),
		Entry("package", "system", "package", "--target-dir", "tempDir", "--name", "package.zip", "--for-offline-installation"),
	)
})
