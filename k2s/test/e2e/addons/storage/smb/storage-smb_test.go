// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package smb_share

import (
	"context"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"

	"io/ioutil"

	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"
	"github.com/siemens-healthineers/k2s/test/framework/os"

	"encoding/json"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

type shareConfig struct {
	WinMountPath     string `json:"winMountPath"`
	LinuxMountPath   string `json:"linuxMountPath"`
	StorageClassName string `json:"storageClassName"`
}

const (
	addonName          = "storage"
	implementationName = "smb"
	namespace          = "smb-share-test"
	secretName         = "regcred"

	linuxWorkloadName1   = "smb-share-test-linux1"
	linuxWorkloadName2   = "smb-share-test-linux2"
	windowsWorkloadName1 = "smb-share-test-windows1"
	windowsWorkloadName2 = "smb-share-test-windows2"

	linuxTestfileName   = "smb-share-test-linux.file"
	windowsTestfileName = "smb-share-test-windows.txt"

	testFileCheckTimeout  = time.Minute * 2
	testFileCheckInterval = time.Second * 5
	testClusterTimeout    = time.Minute * 10
)

var (
	namespaceManifestPath = fmt.Sprintf("workloads/%s-namespace.yaml", namespace)
	linuxManifestPath1    = fmt.Sprintf("workloads/%s.yaml", linuxWorkloadName1)
	linuxManifestPath2    = fmt.Sprintf("workloads/%s.yaml", linuxWorkloadName2)
	windowsManifestPath1  = fmt.Sprintf("workloads/%s.yaml", windowsWorkloadName1)
	windowsManifestPath2  = fmt.Sprintf("workloads/%s.yaml", windowsWorkloadName2)

	suite *framework.K2sTestSuite

	skipWindowsWorkloads = false
	shareConfigs         []shareConfig
	orignalShareConfigs  []shareConfig
	configPath           string = filepath.Join(suite.RootDir(), "addons", "storage", "smb", "config", "SmbStorage.json")
)

func TestSmbshare(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "storage", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))

	skipWindowsWorkloads = suite.SetupInfo().SetupConfig.LinuxOnly

	GinkgoWriter.Println("Creating namespace <", namespace, "> and secret <", secretName, "> on cluster..")

	suite.Kubectl().Run(ctx, "apply", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> and secret <", secretName, "> created on cluster")

	data, err := ioutil.ReadFile(configPath) // assumes file is in the root of the test project
	Expect(err).ToNot(HaveOccurred())

	err = json.Unmarshal(data, &shareConfigs)
	Expect(err).ToNot(HaveOccurred())

	// shareConfig represents the configuration for an SMB share used in the test.
	// WinMountPath specifies the path where the SMB share is mounted on Windows.
	// LinuxMountPath specifies the path where the SMB share is mounted on Linux.
	// StorageClassName defines the name of the storage class associated with the SMB share.
	// *****************************************************************
	//  adding one more values in shareConfig  for testing
	// the ability to create multiple shares with different configurations.
	newConfig := shareConfig{
		WinMountPath:     "C:/k8s-smb-share2",
		LinuxMountPath:   "/mnt/k8s-smb-share2",
		StorageClassName: "smb1",
	}
	orignalShareConfigs = shareConfigs
	shareConfigs = append(shareConfigs, newConfig)
	updatedData, err := json.MarshalIndent(shareConfigs, "", "  ")
	if err != nil {
		panic(fmt.Errorf("failed to marshal JSON: %w", err))
	}

	if err := ioutil.WriteFile(configPath, updatedData, 0644); err != nil {
		panic(fmt.Errorf("failed to write JSON: %w", err))
	}

})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Deleting namespace <", namespace, "> and secret <", secretName, "> on cluster..")

	suite.Kubectl().Run(ctx, "delete", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> and secret <", secretName, "> deleted on cluster")
	GinkgoWriter.Println("Checking if addon is disabled..")

	addonsStatus := suite.K2sCli().GetAddonsStatus(ctx)
	enabled := addonsStatus.IsAddonEnabled(addonName, implementationName)

	if enabled {
		GinkgoWriter.Println("Addon is still enabled, disabling it..")

		output := suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

		GinkgoWriter.Println(output)
	} else {
		GinkgoWriter.Println("Addon is disabled.")
	}

	revertData, err := json.MarshalIndent(orignalShareConfigs, "", "  ")
	Expect(err).ToNot(HaveOccurred(), "Failed to marshal original config for restore")

	err = ioutil.WriteFile(configPath, revertData, 0644)
	Expect(err).ToNot(HaveOccurred(), "Failed to revert config")

	suite.TearDown(ctx)
})

var _ = Describe(fmt.Sprintf("%s Addon, %s Implementation", addonName, implementationName), Ordered, func() {
	Describe("status command", func() {
		Context("default output", func() {
			It("displays disabled message", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, implementationName)

				Expect(output).To(SatisfyAll(
					MatchRegexp(`ADDON STATUS`),
					MatchRegexp(`Implementation .+%s.+ of Addon .+%s.+ is .+disabled.+`, implementationName, addonName),
				))
			})
		})

		Context("JSON output", func() {
			It("displays JSON", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, implementationName, "-o", "json")

				var status status.AddonPrintStatus

				Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

				Expect(status.Name).To(Equal(addonName))
				Expect(status.Implementation).To(Equal(implementationName))
				Expect(status.Enabled).NotTo(BeNil())
				Expect(*status.Enabled).To(BeFalse())
				Expect(status.Props).To(BeNil())
				Expect(status.Error).To(BeNil())
			})
		})
	})

	Describe("disable command", func() {
		It("displays already-disabled message and exits with non-zero", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "disable", addonName, implementationName, "-f", "-o")

			Expect(output).To(SatisfyAll(
				ContainSubstring("disable"),
				ContainSubstring(addonName),
				MatchRegexp(`Addon \'%s %s\' is already disabled`, addonName, implementationName),
			))
		})
	})

	Describe("enable command", func() {
		When("SMB host type is Windows", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "enable", addonName, implementationName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", addonName, implementationName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath1)
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath2)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath1)
				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath2)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath1)
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath2)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath1)
				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath2)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx)
			})
		})
	})

	Describe("enable command", func() {
		When("SMB host type is linux", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "enable", addonName, implementationName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("prints already-enabled message on enable command and exits with non-zero", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, cli.ExitCodeFailure, "addons", "enable", addonName, implementationName)

				Expect(output).To(ContainSubstring("already enabled"))
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("linux", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath1)
				suite.Kubectl().Run(ctx, "apply", "-f", linuxManifestPath2)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath1)
				suite.Kubectl().Run(ctx, "apply", "-f", windowsManifestPath2)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectLinuxWorkloadToRun(ctx)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWindowsWorkloadToRun(ctx)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath1)
				suite.Kubectl().Run(ctx, "delete", "-f", linuxManifestPath2)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath1)
				suite.Kubectl().Run(ctx, "delete", "-f", windowsManifestPath2)
			})

			It("disposes Linux-based workloads", func(ctx context.Context) {
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(linuxWorkloadName2, namespace, ctx)
			})

			It("disposes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName1, namespace, ctx)
				suite.Cluster().ExpectStatefulSetToBeDeleted(windowsWorkloadName2, namespace, ctx)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx)
			})
		})
	})
})

func expectLinuxWorkloadToRun(ctx context.Context) {
	for i, cfg := range shareConfigs {
		i++
		linuxWorkloadName := fmt.Sprintf("smb-share-test-linux%d", i) // e.g., smb-share-test-linux-1, -2, etc.

		suite.Cluster().ExpectStatefulSetToBeReady(linuxWorkloadName, namespace, 1, ctx)

		Eventually(os.IsFileYoungerThan).
			WithArguments(testFileCheckInterval, cfg.WinMountPath, linuxTestfileName).
			WithTimeout(testFileCheckTimeout).
			WithPolling(suite.TestStepPollInterval()).
			WithContext(ctx).
			Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", linuxWorkloadName))
	}
}

func expectWindowsWorkloadToRun(ctx context.Context) {
	if skipWindowsWorkloads {
		Skip("Linux-only setup")
	}
	for i, cfg := range shareConfigs {
		i++
		windowsWorkloadName := fmt.Sprintf("smb-share-test-windows%d", i) // e.g., smb-share-test-linux-1, -2, etc.

		suite.Cluster().ExpectStatefulSetToBeReady(windowsWorkloadName, namespace, 1, ctx)

		Eventually(os.IsFileYoungerThan).
			WithArguments(testFileCheckInterval, cfg.WinMountPath, windowsTestfileName).
			WithTimeout(testFileCheckTimeout).
			WithPolling(suite.TestStepPollInterval()).
			WithContext(ctx).
			Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", windowsWorkloadName))
	}
}

func disableAddon(ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, implementationName, "-f", "-o")

	Expect(output).To(SatisfyAll(
		ContainSubstring("disable"),
		ContainSubstring(addonName),
		MatchRegexp("'k2s addons disable %s %s' completed", addonName, implementationName),
	))
}

func expectStatusToBePrinted(smbHostType string, ctx context.Context) {
	output := suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, implementationName)

	Expect(output).To(SatisfyAll(
		MatchRegexp("ADDON STATUS"),
		MatchRegexp(`Implementation .+%s.+ of Addon .+%s.+ is .+enabled.+`, implementationName, addonName),
		MatchRegexp("SmbHostType: .+%s.+", smbHostType),
		MatchRegexp("SMB share is working"),
		MatchRegexp("CSI Pods are running"),
	))

	output = suite.K2sCli().RunOrFail(ctx, "addons", "status", addonName, implementationName, "-o", "json")

	var status status.AddonPrintStatus

	Expect(json.Unmarshal([]byte(output), &status)).To(Succeed())

	Expect(status.Name).To(Equal(addonName))
	Expect(status.Implementation).To(Equal(implementationName))
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
		MatchRegexp("'k2s addons enable %s %s' completed", addonName, implementationName),
	))
}
