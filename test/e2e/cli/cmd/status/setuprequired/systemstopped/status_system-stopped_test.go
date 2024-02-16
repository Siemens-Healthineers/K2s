// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemstopped

import (
	"context"
	"encoding/json"

	"k2s/cmd/status/load"
	"k2s/setupinfo"

	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/types"

	"k2sTest/e2e/cli/cmd/status/setuprequired/common"
	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestStatus(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status CLI Command Acceptance Tests", Label("cli", "status", "acceptance", "setup-required", "invasive", "setup=k2s", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped)
	addons = suite.AddonsAdditionalInfo().AllAddons()
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

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
		})

		It("prints version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", common.VersionRegex))
		})

		It("prints addons", func() {
			common.ExpectAddonsGetPrinted(output, addons)
		})

		It("states that system is not running with details about what is not running", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				ContainSubstring("The system is not running."),
				ContainSubstring("'KubeMaster' not running, state is 'Off' (VM)"),
			}

			if suite.SetupInfo().Name == setupinfo.SetupNamek2s {
				matchers = append(matchers,
					ContainSubstring("'flanneld' not running (service)"),
					ContainSubstring("'kubelet' not running (service)"),
					ContainSubstring("'kubeproxy' not running (service)"))
			} else if suite.SetupInfo().Name == setupinfo.SetupNameMultiVMK8s && !suite.SetupInfo().LinuxOnly {
				matchers = append(matchers,
					ContainSubstring("'WinNode' not running, state is 'Off' (VM)"))
			}

			Expect(output).To(SatisfyAll(matchers...))
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

		It("prints setup", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Setup: .+%s.+,", suite.SetupInfo().Name))
		})

		It("prints version", func(ctx context.Context) {
			Expect(output).To(MatchRegexp("Version: .+%s.+", common.VersionRegex))
		})

		It("prints addons", func() {
			common.ExpectAddonsGetPrinted(output, addons)
		})

		It("states that system is not running with details about what is not running", func(ctx context.Context) {
			matchers := []types.GomegaMatcher{
				ContainSubstring("The system is not running."),
				ContainSubstring("'KubeMaster' not running, state is 'Off' (VM)"),
			}

			if suite.SetupInfo().Name == setupinfo.SetupNamek2s {
				matchers = append(matchers,
					ContainSubstring("'flanneld' not running (service)"),
					ContainSubstring("'kubelet' not running (service)"),
					ContainSubstring("'kubeproxy' not running (service)"))
			} else if suite.SetupInfo().Name == setupinfo.SetupNameMultiVMK8s && !suite.SetupInfo().LinuxOnly {
				matchers = append(matchers,
					ContainSubstring("'WinNode' not running, state is 'Off' (VM)"))
			}

			Expect(output).To(SatisfyAll(matchers...))
		})
	})

	Context("json output", func() {
		var status load.Status

		BeforeAll(func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "status", "-o", "json")

			Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())
		})

		It("contains setup info", func() {
			Expect(*status.SetupInfo.Name).To(Equal(suite.SetupInfo().Name))
			Expect(*status.SetupInfo.Version).To(MatchRegexp(common.VersionRegex))
			Expect(status.SetupInfo.Error).To(BeNil())
			Expect(*status.SetupInfo.LinuxOnly).To(Equal(suite.SetupInfo().LinuxOnly))
		})

		It("contains running state", func() {
			Expect(status.RunningState.IsRunning).To(BeFalse())
			Expect(status.RunningState.Issues).To(ContainElements(
				ContainSubstring("not running, state is 'Off' (VM)"),
				ContainSubstring("'flanneld' not running (service)"),
				ContainSubstring("'kubelet' not running (service)"),
				ContainSubstring("'kubeproxy' not running (service)"),
			))
		})

		It("does not contain any other info", func() {
			Expect(status.Nodes).To(BeNil())
			Expect(status.Pods).To(BeNil())
			Expect(status.K8sVersionInfo).To(BeNil())
		})
	})
})
