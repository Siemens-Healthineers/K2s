// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"encoding/json"
	"k2s/cmd/image"
	"k2s/setupinfo"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
)

var suite *framework.K2sTestSuite

func TestImage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "image CLI Commands Acceptance Tests", Label("cli", "image", "acceptance", "no-setup"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("image", func() {
	DescribeTable("print system-not-installed message",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().Run(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("build", "image", "build"),
		Entry("clean", "image", "clean"),
		Entry("export", "image", "export", "-n", "non-existent", "-t", "non-existent"),
		Entry("import", "image", "import", "-t", "non-existent"),
		Entry("ls default output", "image", "ls"),
		Entry("pull", "image", "pull", "non-existent"),
		Entry("registry add", "image", "registry", "add", "non-existent"),
		Entry("registry ls", "image", "registry", "ls"),
		Entry("registry switch", "image", "registry", "switch", "non-existent"),
		Entry("rm", "image", "rm", "--id", "non-existent"),
	)

	Describe("ls JSON output", Ordered, func() {
		var images image.Images

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "image", "ls", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &images)).To(Succeed())
		})

		It("contains only system-not-installed info", func() {
			Expect(images.ContainerImages).To(BeNil())
			Expect(images.ContainerRegistry).To(BeNil())
			Expect(images.PushedImages).To(BeNil())
			Expect(string(*images.Error)).To(Equal(string(setupinfo.ErrNotInstalledMsg)))
		})
	})
})
