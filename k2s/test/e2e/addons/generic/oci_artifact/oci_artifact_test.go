package addons

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const (
	artifactName   = "oci.zip"
	artifactTag    = "1.0"
	clusterIp      = "172.19.1.100"
	registryPort   = 30500
	testRepo       = "testrepo"
	orasBinaryName = "oras.exe"
)

var suite *framework.K2sTestSuite
var orasExe string

func TestOCIArtifact(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "OCI Artifact Functional Tests", Label("functional", "acceptance", "oci-artifact"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("OCI Artifact operations", Ordered, func() {
	When("Registry addon only", func() {
		Context("addon is enabled {clusterip}", func() {
			BeforeAll(func(ctx context.Context) {
			    orasExe = filepath.Join(suite.RootDir(), "bin", orasBinaryName)
			    GinkgoWriter.Println("orasExe path:", orasExe)
				suite.K2sCli().RunOrFail(ctx, "addons", "enable", "registry", "-o")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", "registry")
				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted(ctx)
			})

			It("registry addon is in enabled state", func(ctx context.Context) {
				addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
				Expect(addonsStatus.IsAddonEnabled("registry", "")).To(BeTrue())
			})

			It("local container registry is configured", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "image", "registry", "ls")
				Expect(output).Should(ContainSubstring("k2s.registry.local"), "Local Registry was not enabled")
			})

			It("registry is reachable", func(ctx context.Context) {
                url := fmt.Sprintf("http://%s:%d", clusterIp, registryPort)
				expectHttpGetStatusOk(ctx, url)
			})

            It("pushes the zip file as OCI artifact", func(ctx context.Context) {
                Expect(os.Stat(artifactName)).ToNot(BeNil())
                suite.Cli().ExecOrFail(ctx, orasExe, "push", "--insecure","--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag), fmt.Sprintf("%s:application/zip", artifactName))
            })

            It("verifies the manifest after push", func(ctx context.Context) {
                output := suite.Cli().ExecOrFail(ctx, orasExe, "manifest", "fetch", "--insecure","--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag))
                Expect(output).To(ContainSubstring("application/zip"))
            })

            It("pulls the artifact", func(ctx context.Context) {
                suite.Cli().ExecOrFail(ctx, orasExe, "pull", "--insecure","--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag))
            })

            It("pulls the artifact to a specific directory", func(ctx context.Context) {
                suite.Cli().ExecOrFail(ctx, orasExe, "pull", "--insecure","--plain-http", fmt.Sprintf("%s:%d/%s:%s", clusterIp, registryPort, testRepo, artifactTag), "-o", "./downloaded")
                Expect(os.Stat("./downloaded/" + artifactName)).ToNot(BeNil())
            })

			AfterAll(func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "addons", "disable", "registry", "-o")
				_ = os.RemoveAll("./downloaded")
			})
		})
	})
})

func expectStatusToBePrinted(ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "status")
	Expect(output).To(ContainSubstring("registry"))
}

func expectHttpGetStatusOk(ctx context.Context, url string) {
	output, err := suite.HttpClient().Get(ctx, url, nil)
	Expect(err).To(BeNil())
	Expect(string(output)).To(ContainSubstring("zot OCI-native Container Image Registry"))
}