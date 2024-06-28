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

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image"

	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/host"
	"github.com/siemens-healthineers/k2s/internal/setupinfo"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

var suite *framework.K2sTestSuite

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "no-setup", "corrupted-state"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("image", Ordered, func() {
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
		configPath = filepath.Join(config.Host.K2sConfigDir, "setup.json")

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
		Entry("build", "image", "build"),
		Entry("clean", "image", "clean"),
		Entry("export", "image", "export", "-n", "non-existent", "-t", "non-existent"),
		Entry("import", "image", "import", "-t", "non-existent"),
		Entry("ls default output", "image", "ls"),
		Entry("pull", "image", "pull", "non-existent"),
		Entry("push", "image", "push", "non-existent"),
		Entry("tag", "image", "tag", "non-existent", "non-existent"),
		Entry("registry add", "image", "registry", "add", "non-existent"),
		Entry("registry ls", "image", "registry", "ls"),
		Entry("registry switch", "image", "registry", "switch", "non-existent"),
		Entry("rm", "image", "rm", "--id", "non-existent"),
	)

	Describe("ls JSON output", Ordered, func() {
		var images image.PrintImages

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "image", "ls", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &images)).To(Succeed())
		})

		It("contains only system-in-corrupted-state info and exits with non-zero", func() {
			Expect(images.ContainerImages).To(BeNil())
			Expect(images.ContainerRegistry).To(BeNil())
			Expect(images.PushedImages).To(BeNil())
			Expect(*images.Error).To(Equal(setupinfo.ErrSystemInCorruptedState.Error()))
		})
	})
})
