// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package systemrequired

import (
	"context"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/dsl"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type outputWriter struct {
	messages []string
}

func (g *outputWriter) Flush() {}

func (g *outputWriter) WriteStdErr(message string) {
	Fail(message)
}

func (g *outputWriter) WriteStdOut(message string) {
	g.messages = append(g.messages, message)
}

var suite *framework.K2sTestSuite
var k2s *dsl.K2s

func TestSystem(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system CLI Commands Acceptance Tests", Label("cli", "system", "setup-required"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemStateIrrelevant, framework.ClusterTestStepPollInterval(200*time.Millisecond))
	k2s = dsl.NewK2s(suite)

	DeferCleanup(suite.TearDown)
})

var _ = Describe("system", Ordered, func() {
	Describe("package", Label("package", "acceptance"), func() {
		It("prints system-installed-error and exits", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "system", "package", "--target-dir", ".", "--name", "package.zip")

			Expect(output).To(SatisfyAll(
				ContainSubstring("is installed"),
				ContainSubstring("Please uninstall"),
			))
		})
	})

	Describe("upgrade", Label("upgrade", "acceptance", "invasive"), func() {
		When("wrong K8s context is in use", func() {
			BeforeEach(func(ctx context.Context) {
				k2s.SetWrongK8sContext(ctx)

				DeferCleanup(k2s.ResetK8sContext)
			})

			It("fails", func(ctx context.Context) {
				result := k2s.ShowStatus(ctx)

				result.VerifyWrongK8sContextFailure()
			})
		})
	})

	// TODO: set stdout?
	// Describe("kubectl pkg", Label("integration", "internal", "core", "users", "k8s", "kubectl"), func() {
	// 	Describe("Exec", func() {
	// 		It("retrieves kubectl client version", func() {
	// 			rootDir, err := os.RootDir()
	// 			Expect(err).ToNot(HaveOccurred())

	// 			writer := &outputWriter{messages: []string{}}
	// 			executor := ios.NewCmdExecutor(writer)
	// 			sut := kubectl.NewKubectl(rootDir, executor)

	// 			Expect(sut.Exec("version", "--client", "-o", "json")).To(Succeed())

	// 			jsonString := strings.Join(writer.messages, "")

	// 			var output map[string]any
	// 			Expect(json.Unmarshal([]byte(jsonString), &output)).To(Succeed())
	// 			Expect(output["clientVersion"].(map[string]any)["major"]).To(Equal("1"))
	// 		})
	// 	})
	// })
})
