// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT
package systemstopped

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/image"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/cli"
	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "setup-required", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("image", func() {
	DescribeTable("print system-not-running message and exits with non-zero",
		func(ctx context.Context, args ...string) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, args...)

			Expect(output).To(ContainSubstring("not running"))
		},
		Entry("ls default output", "image", "ls"),
		Entry("build", "image", "build"),
		Entry("pull", "image", "pull", "non-existent"),
		Entry("push", "image", "push", "-n", "non-existent"),
		Entry("tag", "image", "tag", "-n", "non-existent", "-t", "non-existent"),
		Entry("rm", "image", "rm", "--id", "non-existent"),
		Entry("clean", "image", "clean"),
		Entry("export", "image", "export", "-n", "non-existent", "-t", "non-existent"),
		Entry("import", "image", "import", "-t", "non-existent"),
		Entry("registry add", "image", "registry", "add", "non-existent"),
		Entry("registry rm", "image", "registry", "rm", "non-existent"),
	)

	Describe("ls JSON output", Ordered, func() {
		var images image.PrintImages

		BeforeAll(func(ctx context.Context) {
			output, _ := suite.K2sCli().ExpectedExitCode(cli.ExitCodeFailure).Exec(ctx, "image", "ls", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &images)).To(Succeed())
		})

		It("contains only system-not-running info and exits with non-zero", func() {
			Expect(images.ContainerImages).To(BeNil())
			Expect(images.ContainerRegistry).To(BeNil())
			Expect(images.PushedImages).To(BeNil())
			Expect(*images.Error).To(Equal("system-not-running"))
		})
	})
})
