// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package smb_share

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"github.com/siemens-healthineers/k2s/test/framework/os"

	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	"encoding/json"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

const (
	addonName  = "storage"
	namespace  = "smb-share-test"
	secretName = "regcred"

	linuxWorkloadName   = "smb-share-test-linux"
	windowsWorkloadName = "smb-share-test-windows"

	linuxTestfileName   = "smb-share-test-linux.file"
	windowsTestfileName = "smb-share-test-windows.txt"

	testFileCheckTimeout  = time.Minute * 2
	testFileCheckInterval = time.Second * 5
	testClusterTimeout    = time.Minute * 10
)

var (
	namespaceManifestPath = fmt.Sprintf("workloads/%s-namespace.yaml", namespace)
	linuxManifestPath     = fmt.Sprintf("workloads/%s.yaml", linuxWorkloadName)
	windowsManifestPath   = fmt.Sprintf("workloads/%s.yaml", windowsWorkloadName)

	suite *framework.K2sTestSuite

	skipWindowsWorkloads = false
)

func TestSmbshare(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage Addon Acceptance Tests", Label("addon", "acceptance", "internet-required", "setup-required", "invasive", "storage", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))

	skipWindowsWorkloads = suite.SetupInfo().SetupConfig.LinuxOnly

	GinkgoWriter.Println("Creating namespace <", namespace, "> and secret <", secretName, "> on cluster..")

	suite.Kubectl().Run(ctx, "apply", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> and secret <", secretName, "> created on cluster")
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Deleting namespace <", namespace, "> and secret <", secretName, "> on cluster..")

	suite.Kubectl().Run(ctx, "delete", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> and secret <", secretName, "> deleted on cluster")
	GinkgoWriter.Println("Checking if addon is disabled..")

	addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
	enabled := addonsStatus.IsAddonEnabled(addonName, "")

	if enabled {
		GinkgoWriter.Println("Addon is still enabled, disabling it..")

		output := suite.K2sCli().Run(ctx, "addons", "disable", addonName, "-f", "-o")

		GinkgoWriter.Println(output)
	} else {
		GinkgoWriter.Println("Addon is disabled.")
	}

	suite.TearDown(ctx)
})

var _ = Describe(fmt.Sprintf("%s Addon", addonName), Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", addonName)

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Addon .+%s.+ is .+disabled.+`, addonName),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "status", addonName, "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal(addonName))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		It("displays already-disabled message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "disable", addonName, "-f", "-o")

			Expect(output).To(SatisfyAll(
				ContainSubstring("disable"),
				ContainSubstring(addonName),
				MatchRegexp(`Addon \'%s\' is already disabled`, addonName),
			))
		})
	})

	Describe("enable command", func() {
		When("SMB host type is Windows", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "enable", addonName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addonName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx)
			})
		})
	})

	Describe("enable command", func() {
		When("SMB host type is linux", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().Run(ctx, "addons", "enable", addonName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "addons", "enable", addonName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("linux", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().Run(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx)
			})
		})
	})
})

func expectLinuxWorkloadToRun(ctx context.Context) {
	suite.Cluster().ExpectStatefulSetToBeReady(linuxWorkloadName, namespace, 1, ctx)

	Eventually(os.IsFileYoungerThan).
		WithArguments(testFileCheckInterval, k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes).ShareDir, linuxTestfileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue())
}

func expectWindowsWorkloadToRun(ctx context.Context) {
	if skipWindowsWorkloads {
		Skip("Linux-only setup")
	}

	suite.Cluster().ExpectStatefulSetToBeReady(windowsWorkloadName, namespace, 1, ctx)

	Eventually(os.IsFileYoungerThan).
		WithArguments(testFileCheckInterval, k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes).ShareDir, windowsTestfileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue())
}

func disableAddon(ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "disable", addonName, "-f", "-o")

	Expect(output).To(SatisfyAll(
		ContainSubstring("disable"),
		ContainSubstring(addonName),
		MatchRegexp("'addons disable %s' completed", addonName),
	))
}

func expectStatusToBePrinted(smbHostType string, ctx context.Context) {
	output := suite.K2sCli().Run(ctx, "addons", "status", addonName)

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Addon .+%s.+ is .+enabled.+`, addonName),
		MatchRegexp("SmbHostType: .+%s.+", smbHostType),
		MatchRegexp("SMB share is working"),
		MatchRegexp("CSI Pods are running"),
	))

	output = suite.K2sCli().Run(ctx, "addons", "status", addonName, "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal(addonName))
	Expect(status.Error).To(BeNil())
	Expect(status.Enabled).NotTo(BeNil())
	Expect(*status.Enabled).To(BeTrue())
	Expect(status.Props).NotTo(BeNil())
	Expect(status.Props).To(ContainElements(
		SatisfyAll(
			HaveField("Name", "SmbHostType"),
			HaveField("Value", smbHostType)),
		SatisfyAll(
			HaveField("Name", "IsSmbShareWorking"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("SMB share is working")))),
		SatisfyAll(
			HaveField("Name", "AreCsiPodsRunning"),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("CSI Pods are running")))),
	))
}

func expectEnableMessage(output string, smbHostType string) {
	Expect(output).To(SatisfyAll(
		MatchRegexp("Enabling addon \\'%s\\' with SMB host type \\'%s\\'", addonName, smbHostType),
		MatchRegexp("'addons enable %s' completed", addonName),
	))
}
