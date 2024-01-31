// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package nosetup

import (
	"context"
	"encoding/json"
	"k2s/cmd/status/load"
	"k2s/setupinfo"
	"time"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
)

var suite *framework.K2sTestSuite

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "no-setup"), framework.ClusterTestStepPollInterval(100*time.Millisecond))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.NoSetupInstalled)
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("status", Ordered, func() {
	Context("default output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().Run(ctx, "status")
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints system-not-installed message", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Context("extended output", func() {
		var output string

		BeforeAll(func(ctx context.Context) {
			output = suite.K2sCli().Run(ctx, "status", "-o", "wide")
		})

		It("prints a header", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("K2s SYSTEM STATUS"))
		})

		It("prints system-not-installed message", func(ctx context.Context) {
			Expect(output).To(ContainSubstring("not installed"))
		})
	})

	Context("JSON output", func() {
		var status load.Status

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "status", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains system-not-installed info", func() {
			Expect(status.SetupInfo.Name).To(BeNil())
			Expect(status.SetupInfo.Version).To(BeNil())
			Expect(*status.SetupInfo.Error).To(Equal(setupinfo.ErrNotInstalledMsg))
			Expect(status.SetupInfo.LinuxOnly).To(BeNil())
		})

		It("does not contain any other info", func() {
			Expect(status.EnabledAddons).To(BeNil())
			Expect(status.RunningState).To(BeNil())
			Expect(status.Nodes).To(BeNil())
			Expect(status.Pods).To(BeNil())
			Expect(status.K8sVersionInfo).To(BeNil())
		})
	})
})
