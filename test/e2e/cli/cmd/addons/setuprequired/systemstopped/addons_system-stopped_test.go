// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemstopped

import (
	"context"
	"encoding/json"
	"fmt"
	"k2s/addons/status"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestLs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests for K2s being stopped", Label("cli", "acceptance", "setup-required", "addons", "system-stopped"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeStopped, framework.ClusterTestStepPollInterval(500*time.Millisecond))
	addons = k2s.AllAddons(suite.RootDir())
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", Ordered, func() {
	Describe("status", func() {
		Context("standard output", func() {
			It("prints system-not-running message for all addons", func(ctx context.Context) {
				for _, addon := range addons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().Run(ctx, "addons", "status", addon.Metadata.Name)

					Expect(output).To(ContainSubstring("not running"))
				}
			})
		})

		Context("JSON output", func() {
			It("contains only system-not-running info and name", func(ctx context.Context) {
				for _, addon := range addons {
					GinkgoWriter.Println("Calling addons status for", addon.Metadata.Name)

					output := suite.K2sCli().Run(ctx, "addons", "status", addon.Metadata.Name, "-o", "json")

					var status status.AddonPrintStatus

					Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

					Expect(status.Enabled).To(BeNil())
					Expect(status.Name).To(Equal(addon.Metadata.Name))
					Expect(string(*status.Error)).To(Equal("system-not-running"))
					Expect(status.Props).To(BeEmpty())
				}
			})
		})
	})

	Describe("enable", func() {
		It("prints system-not-running message for all addons", func(ctx context.Context) {
			for _, addon := range addons {
				if addon.Metadata.Name != "dashboard" && addon.Metadata.Name != "exthttpaccess" && addon.Metadata.Name != "gateway-nginx" && addon.Metadata.Name != "gpu-node" && addon.Metadata.Name != "ingress-nginx" && addon.Metadata.Name != "kubevirt" {
					Skip(fmt.Sprintf("not yet implemented for addon '%s'", addon.Metadata.Name))
				}

				GinkgoWriter.Println("Calling addons enable for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "enable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("not running"))
			}
		})
	})

	Describe("disable", func() {
		It("prints system-not-running message for all addons", func(ctx context.Context) {
			for _, addon := range addons {
				if addon.Metadata.Name != "dashboard" && addon.Metadata.Name != "exthttpaccess" && addon.Metadata.Name != "gateway-nginx" && addon.Metadata.Name != "gpu-node" && addon.Metadata.Name != "ingress-nginx" && addon.Metadata.Name != "kubevirt" {
					Skip(fmt.Sprintf("not yet implemented for addon '%s'", addon.Metadata.Name))
				}

				GinkgoWriter.Println("Calling addons disable for", addon.Metadata.Name)

				output := suite.K2sCli().Run(ctx, "addons", "disable", addon.Metadata.Name)

				Expect(output).To(ContainSubstring("not running"))
			}
		})
	})
})
