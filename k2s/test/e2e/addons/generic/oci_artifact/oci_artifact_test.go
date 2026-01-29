// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package addons

import (
	"archive/zip"
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/test/framework"
)

const (
	artifactName = "oci.zip"
	artifactTag  = "1.0"
	clusterIp    = "172.19.1.100"
	registryPort = 30500
	testRepo     = "test-repo"
	orasFileName = "oras.exe"
)

var suite *framework.K2sTestSuite
var orasFilePath string
var testFailed = false

func TestOCIArtifact(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "OCI Artifact Functional Tests", Label("functional", "acceptance", "oci-artifact", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(time.Millisecond*200))
})

var _ = AfterSuite(func(ctx context.Context) {
	if testFailed {
		suite.K2sCli().MustExec(ctx, "system", "dump", "-S", "-o")
	}

	suite.TearDown(ctx)
})

var _ = AfterEach(func() {
	if CurrentSpecReport().Failed() {
		testFailed = true
	}
})

var _ = Describe("OCI Artifact operations", Ordered, func() {
	When("registry addon is enabled", func() {
		BeforeAll(func(ctx context.Context) {
			orasFilePath = filepath.Join(suite.RootDir(), "bin", orasFileName)
			GinkgoWriter.Println("oras.exe path:", orasFilePath)

			zipFile, err := os.Create(artifactName)
			Expect(err).To(BeNil())
			defer zipFile.Close()

			zipWriter := zip.NewWriter(zipFile)
			defer zipWriter.Close()

			sampleFile, err := zipWriter.Create("sample.txt")
			Expect(err).To(BeNil())
			_, err = sampleFile.Write([]byte("This is a sample text file inside the zip."))
			Expect(err).To(BeNil())

			suite.K2sCli().MustExec(ctx, "addons", "enable", "registry", "-o")

			DeferCleanup(func(ctx context.Context) {
				suite.K2sCli().MustExec(ctx, "addons", "disable", "registry", "-o")

				os.RemoveAll("./downloaded")
				os.Remove(artifactName)
			})
		})

		It("local container registry is configured", func(ctx context.Context) {
			output := suite.K2sCli().MustExec(ctx, "image", "registry", "ls")

			Expect(output).Should(ContainSubstring("k2s.registry.local"), "Local Registry was not enabled")
		})

		It("registry is reachable", func(ctx context.Context) {
			url := fmt.Sprintf("http://%s:%d", clusterIp, registryPort)

			output, err := suite.HttpClient().Get(ctx, url)

			Expect(err).To(BeNil())
			Expect(string(output)).To(ContainSubstring("zot OCI-native Container Image Registry"))
		})

		It("pushes the zip file as OCI artifact", func(ctx context.Context) {
			Expect(os.Stat(artifactName)).ToNot(BeNil())

			suite.Cli(orasFilePath).MustExec(ctx, "push", "--insecure", "--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag), fmt.Sprintf("%s:application/zip", artifactName))
		})

		It("verifies the manifest after push", func(ctx context.Context) {
			output := suite.Cli(orasFilePath).MustExec(ctx, "manifest", "fetch", "--insecure", "--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag))

			Expect(output).To(ContainSubstring("application/zip"))
		})

		It("pulls the artifact", func(ctx context.Context) {
			suite.Cli(orasFilePath).MustExec(ctx, "pull", "--insecure", "--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag))
		})

		It("pulls the artifact to a specific directory", func(ctx context.Context) {
			suite.Cli(orasFilePath).MustExec(ctx, "pull", "--insecure", "--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag), "-o", "./downloaded")

			Expect(os.Stat("./downloaded/" + artifactName)).ToNot(BeNil())
		})
	})
})
