// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
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

var _ = Describe("image commands", func() {
	DescribeTable("print not-installed message",
		func(ctx context.Context, args ...string) {
			output := suite.K2sCli().Run(ctx, args...)

			Expect(output).To(ContainSubstring("not installed"))
		},
		Entry("image build", "image", "build"),
		Entry("image clean", "image", "clean"),
		Entry("image export", "image", "export", "-n", "non-existent", "-t", "non-existent"),
		Entry("image import", "image", "import", "-t", "non-existent"),
		Entry("image ls", "image", "ls"),
		Entry("image pull", "image", "pull", "non-existent"),
		Entry("image registry add", "image", "registry", "add", "non-existent"),
		Entry("image registry ls", "image", "registry", "ls"),
		Entry("image registry switch", "image", "registry", "switch", "non-existent"),
		Entry("image rm", "image", "rm", "--id", "non-existent"),
	)
})
