// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package security

import (
	"context"
	"encoding/json"
	"os"
	"path"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const addonName = "security"

var suite *framework.K2sTestSuite

func TestSecurity(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "security Addon Acceptance Tests", Label("addon", "acceptance", "setup-required", "invasive", "security", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled)
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Checking if addon is disabled..")

	addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
	enabled := addonsStatus.IsAddonEnabled(addonName, "")

	if enabled {
		GinkgoWriter.Println("Addon is still enabled, disabling it..")

		output := suite.K2sCli().Run(ctx, "addons", "disable", addonName, "-o")

		GinkgoWriter.Println(output)
	} else {
		GinkgoWriter.Println("Addon is disabled.")
	}

	suite.TearDown(ctx)
})

var _ = Describe("'security' addon", Ordered, func() {
	It("prints already-disabled message on disable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", addonName)

		Expect(output).To(ContainSubstring("already disabled"))
	})

	It("enables the addon", func(ctx context.Context) {
		args := []string{"addons", "enable", addonName, "-o"}
		if suite.Proxy() != "" {
			args = append(args, "-p", suite.Proxy())
		}
		suite.K2sCli().Run(ctx, args...)
	})

	It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
		output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addonName)

		Expect(output).To(ContainSubstring("already enabled"))
	})

	It("prints the status user-friendly", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "status", addonName)

		Expect(output).To(SatisfyAll(
			MatchRegexp("ADDON STATUS"),
			MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
			MatchRegexp("The cert-manager API is ready"),
			MatchRegexp("The CA root certificate is available"),
		))
	})

	It("prints the status as JSON", func(ctx context.Context) {
		output := suite.K2sCli().Run(ctx, "addons", "status", addonName, "-o", "json")

		var status status.AddonPrintStatus

		Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

		Expect(status.Name).To(Equal(addonName))
		Expect(status.Error).To(BeNil())
		Expect(status.Enabled).NotTo(BeNil())
		Expect(*status.Enabled).To(BeTrue())
		Expect(status.Props).NotTo(BeNil())
		Expect(status.Props).To(ContainElements(
			SatisfyAll(
				HaveField("Name", "IsCertManagerAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(ContainSubstring("The cert-manager API is ready")))),
			SatisfyAll(
				HaveField("Name", "IsCaRootCertificateAvailable"),
				HaveField("Value", true),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
				HaveField("Message", gstruct.PointTo(MatchRegexp("The CA root certificate is available"))),
				HaveField("Okay", gstruct.PointTo(BeTrue())),
			)))
	})

	It("installs cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(err).To(BeNil())
	})

	It("creates the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-n", "cert-manager", "ca-issuer-root-secret")
		Expect(output).To(ContainSubstring("ca-issuer-root-secret"))
	})

	It("disables the addon", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "disable", addonName, "-o")
	})

	It("disables default ingress addon", func(ctx context.Context) {
		suite.K2sCli().Run(ctx, "addons", "disable", "ingress", "nginx", "-o")
	})

	It("uninstalls cmctl.exe, the cert-manager CLI", func(ctx context.Context) {
		cmCtlPath := path.Join(suite.RootDir(), "bin", "cmctl.exe")
		_, err := os.Stat(cmCtlPath)
		Expect(os.IsNotExist(err)).To(BeTrue())
	})

	It("removed the ca-issuer-root-secret", func(ctx context.Context) {
		output := suite.Kubectl().Run(ctx, "get", "secrets", "-A")
		Expect(output).NotTo(ContainSubstring("ca-issuer-root-secret"))
	})
})
