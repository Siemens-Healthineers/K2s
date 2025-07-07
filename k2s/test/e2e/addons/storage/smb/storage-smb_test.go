// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package smb_share

import (
	"context"
	"fmt"
	"path/filepath"
	"regexp"
	"testing"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/addons/status"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/os"

	bos "os"

	"github.com/siemens-healthineers/k2s/internal/cli"
	kos "github.com/siemens-healthineers/k2s/internal/os"

	//	"github.com/siemens-healthineers/k2s/test/framework/os"

	"encoding/json"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/onsi/gomega/gstruct"
)

type config []configEntry

type configEntry struct {
	WinMountPath     string `json:"winMountPath"`
	LinuxMountPath   string `json:"linuxMountPath"`
	StorageClassName string `json:"storageClassName"`
}

const (
	addonName          = "storage"
	implementationName = "smb"
	namespace          = "smb-share-test"
	secretName         = "regcred"

	linuxManifestDir   = "workloads/linux"
	windowsManifestDir = "workloads/windows"

	linuxWorkloadName1   = "smb-share-test-linux1"
	linuxWorkloadName2   = "smb-share-test-linux2"
	windowsWorkloadName1 = "smb-share-test-windows1"
	windowsWorkloadName2 = "smb-share-test-windows2"

	testConfigFileName = "test-config.json"

	linuxTestfileName   = "smb-share-test-linux.file"
	windowsTestfileName = "smb-share-test-windows.txt"

	testFileCheckTimeout  = time.Minute * 2
	testFileCheckInterval = time.Second * 5
	testClusterTimeout    = time.Minute * 10

	testFileCreationTimeout = time.Minute * 5
	testFileOverallTimeout  = time.Minute * 10
)

var (
	namespaceManifestPath = fmt.Sprintf("workloads/%s-namespace.yaml", namespace)
	suite                 *framework.K2sTestSuite
	skipWindowsWorkloads  = false
	originalConfigPath    string
	storageConfig         config
)

func TestSmbshare(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "storage Addon Acceptance Tests", Label("addon", "addon-ilities", "acceptance", "internet-required", "setup-required", "invasive", "storage", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.EnsureAddonsAreDisabled, framework.ClusterTestStepTimeout(testClusterTimeout))

	skipWindowsWorkloads = suite.SetupInfo().SetupConfig.LinuxOnly

	GinkgoWriter.Println("Creating namespace <", namespace, "> on cluster..")

	suite.Kubectl().Run(ctx, "apply", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> created on cluster")

	originalConfigPath = filepath.Join(suite.RootDir(), "addons", "storage", "smb", "config", "SmbStorage.json")

	Expect(bos.Rename(originalConfigPath, originalConfigPath+"_")).To(Succeed())
	Expect(kos.CopyFile(testConfigFileName, originalConfigPath)).To(Succeed())

	configBytes, err := bos.ReadFile(testConfigFileName)
	Expect(err).ToNot(HaveOccurred())

	Expect(json.Unmarshal(configBytes, &storageConfig)).To(Succeed())
})

var _ = AfterSuite(func(ctx context.Context) {
	GinkgoWriter.Println("Deleting namespace <", namespace, "> on cluster..")

	suite.Kubectl().Run(ctx, "delete", "-f", namespaceManifestPath)

	GinkgoWriter.Println("Namespace <", namespace, "> deleted on cluster")
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

	Expect(bos.Remove(originalConfigPath)).To(Succeed())
	Expect(bos.Rename(originalConfigPath+"_", originalConfigPath)).To(Succeed())

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
				suite.Kubectl().Run(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-k", windowsManifestDir)
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
				disableAddon(ctx, "-f")
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
				suite.Kubectl().Run(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("restarts the cluster", func(ctx context.Context) {
				suite.K2sCli().RunOrFail(ctx, "start")
			})

			It("still runs Linux-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("still runs Windows-based workloads after cluster restart", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-k", windowsManifestDir)
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
				disableAddon(ctx, "-f")
			})
		})
	})

	Describe("enable and disable with keep in Windows", func() {
		When("SMB host type is Windows", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "enable", addonName, implementationName, "-o")

				expectEnableMessage(output, "windows")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("windows", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-k", windowsManifestDir)
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

			It("create the test files", func(ctx context.Context) {
				createTestFiles(ctx, storageConfig[0].WinMountPath)
				createTestFiles(ctx, storageConfig[1].WinMountPath)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-k")
			})

			It("checks that the test files are still available", func(ctx context.Context) {
				expectTestFilesAreAvailable(ctx, storageConfig[0].WinMountPath)
				expectTestFilesAreAvailable(ctx, storageConfig[1].WinMountPath)
			})

			It("checks that the mount file is not available in Windows", func(ctx context.Context) {
				// test that file storageConfig[0].WinMountPath\mountedInVm.txt is not available
				expectFileAreNotAvailableInWindows(ctx, storageConfig[0].WinMountPath)
				expectFileAreNotAvailableInWindows(ctx, storageConfig[1].WinMountPath)
			})

			It("deletes the test files", func(ctx context.Context) {
				deleteTestFiles(ctx, storageConfig[0].WinMountPath)
				deleteTestFiles(ctx, storageConfig[1].WinMountPath)
			})

			It("deletes the mount paths", func(ctx context.Context) {
				deleteMountPath(ctx, storageConfig[0].WinMountPath)
				deleteMountPath(ctx, storageConfig[1].WinMountPath)
			})
		})
	})

	Describe("enable and disable with keep in Linux", func() {
		When("SMB host type is Linux", Ordered, func() {
			It("enables the addon", func(ctx context.Context) {
				output := suite.K2sCli().RunOrFail(ctx, "addons", "enable", addonName, implementationName, "-o", "-t", "linux")

				expectEnableMessage(output, "linux")
			})

			It("prints the status", func(ctx context.Context) {
				expectStatusToBePrinted("linux", ctx)
			})

			It("deploys Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "apply", "-k", linuxManifestDir)
			})

			It("deploys Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "apply", "-k", windowsManifestDir)
			})

			It("runs Linux-based workloads", func(ctx context.Context) {
				// TODO: could be more generic
				expectWorkloadToRun(ctx, linuxWorkloadName1, storageConfig[0].WinMountPath, linuxTestfileName)
				expectWorkloadToRun(ctx, linuxWorkloadName2, storageConfig[1].WinMountPath, linuxTestfileName)
			})

			It("runs Windows-based workloads", func(ctx context.Context) {
				expectWorkloadToRun(ctx, windowsWorkloadName1, storageConfig[0].WinMountPath, windowsTestfileName)
				expectWorkloadToRun(ctx, windowsWorkloadName2, storageConfig[1].WinMountPath, windowsTestfileName)
			})

			It("deletes Linux-based workloads", func(ctx context.Context) {
				suite.Kubectl().Run(ctx, "delete", "-k", linuxManifestDir)
			})

			It("deletes Windows-based workloads", func(ctx context.Context) {
				if skipWindowsWorkloads {
					Skip("Linux-only setup")
				}

				suite.Kubectl().Run(ctx, "delete", "-k", windowsManifestDir)
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

			It("create the test files", func(ctx context.Context) {
				createTestFiles(ctx, storageConfig[0].WinMountPath)
				createTestFiles(ctx, storageConfig[1].WinMountPath)
			})

			It("checks that the test files are still available 1", func(ctx context.Context) {
				expectFileAreAvailableInLinux(ctx, storageConfig[0].LinuxMountPath)
				expectFileAreAvailableInLinux(ctx, storageConfig[1].LinuxMountPath)
			})

			It("disables the addon", func(ctx context.Context) {
				disableAddon(ctx, "-k")
			})

			It("checks that the test files are still available 2", func(ctx context.Context) {
				expectFileAreAvailableInLinux(ctx, "/srv/samba/linux-smb-share1")
				expectFileAreAvailableInLinux(ctx, "/srv/samba/linux-smb-share2")
			})

			It("checks that the mount file is not available in Linux", func(ctx context.Context) {
				expectFileAreNotAvailableInLinux(ctx, "/srv/samba/linux-smb-share1")
				expectFileAreNotAvailableInLinux(ctx, "/srv/samba/linux-smb-share2")
			})

			It("deletes the test files", func(ctx context.Context) {
				deleteFilesOnLinuxMount(ctx)
			})
		})
	})
})

func expectWorkloadToRun(ctx context.Context, workloadName, mountPath, testFileName string) {
	suite.Cluster().ExpectStatefulSetToBeReady(workloadName, namespace, 1, ctx)

	Eventually(os.IsFileYoungerThan).
		WithArguments(testFileCheckInterval, mountPath, testFileName).
		WithTimeout(testFileCheckTimeout).
		WithPolling(suite.TestStepPollInterval()).
		WithContext(ctx).
		Should(BeTrue(), fmt.Sprintf("Expected file check to pass for %s", workloadName))
}

func disableAddon(ctx context.Context, option string) {
	if len(option) == 0 {
		option = "-f"
	}
	output := suite.K2sCli().RunOrFail(ctx, "addons", "disable", addonName, implementationName, "-o", option)

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
		MatchRegexp("SMB share is working, path: \\(%s <-> %s\\)", regexp.QuoteMeta(storageConfig[0].WinMountPath), regexp.QuoteMeta(storageConfig[0].LinuxMountPath)),
		MatchRegexp("SMB share is working, path: \\(%s <-> %s\\)", regexp.QuoteMeta(storageConfig[1].WinMountPath), regexp.QuoteMeta(storageConfig[1].LinuxMountPath)),
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
			HaveField("Name", "ShareForStorageClass_"+storageConfig[0].StorageClassName),
			HaveField("Value", true),
			HaveField("Okay", gstruct.PointTo(BeTrue())),
			HaveField("Message", gstruct.PointTo(ContainSubstring("SMB share is working")))),
		SatisfyAll(
			HaveField("Name", "ShareForStorageClass_"+storageConfig[1].StorageClassName),
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

func createTestFiles(ctx context.Context, mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		filePath := filepath.Join(mountPath, fileName)
		err := bos.WriteFile(filePath, []byte("test content"), 0644)
		Expect(err).NotTo(HaveOccurred())
	}
}

func expectTestFilesAreAvailable(ctx context.Context, mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		// check only if the file exists and is not empty
		Eventually(os.IsFileYoungerThan).
			WithArguments(testFileCreationTimeout, mountPath, fileName).
			WithTimeout(testFileOverallTimeout).
			WithPolling(suite.TestStepPollInterval()).
			WithContext(ctx).
			Should(BeTrue(), fmt.Sprintf("Expected file %s to be available in %s", fileName, mountPath))
	}
}

func deleteTestFiles(ctx context.Context, mountPath string) {
	fileNames := []string{"file1.txt", "file2.txt", "file3.txt"}
	for _, fileName := range fileNames {
		filePath := filepath.Join(mountPath, fileName)
		err := bos.Remove(filePath)
		Expect(err).NotTo(HaveOccurred())
	}
}

func deleteMountPath(ctx context.Context, mountPath string) {
	err := bos.RemoveAll(mountPath)
	Expect(err).NotTo(HaveOccurred())
}

func expectFileAreAvailableInLinux(ctx context.Context, sharefolder string) {
	// execute command and check output if it contains the filename file1.txt and file2.txt
	output := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("ls %s", sharefolder))
	Expect(output).To(ContainSubstring("file1.txt"))
	Expect(output).To(ContainSubstring("file2.txt"))
	Expect(output).To(ContainSubstring("file3.txt"))
}

func deleteFilesOnLinuxMount(ctx context.Context) {
	// if boolLinuxOnly is true, then only delete files on linux mount
	share1 := "/srv/samba/linux-smb-share1"
	share2 := "/srv/samba/linux-smb-share2"

	// execute command and check output if it contains the filename file1.txt and file2.txt
	output1 := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("sudo rm -r %s", share1))
	Expect(output1).To(SatisfyAll(
		ContainSubstring("completed in"),
	))
	output2 := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("sudo rm -r %s", share2))
	Expect(output2).To(SatisfyAll(
		ContainSubstring("completed in"),
	))
}

func expectFileAreNotAvailableInLinux(ctx context.Context, sharefolder string) {
	// execute command and check output if it contains the filename file1.txt and file2.txt
	output := suite.K2sCli().RunOrFail(ctx, "node", "exec", "-i", "172.19.1.100", "-u", "remote", "-c", fmt.Sprintf("ls %s", sharefolder))
	Expect(output).ToNot(ContainSubstring("mountedInVm.txt"))
}

func expectFileAreNotAvailableInWindows(ctx context.Context, sharefolder string) {
	// list in the folder on windows the files and check if the file mountedInVm.txt is not available
	Expect(os.GetFilesMatch(sharefolder, "mountedInVm.txt")).To(BeEmpty(), fmt.Sprintf("Expected file mountedInVm.txt to not be present in %s", sharefolder))
}
