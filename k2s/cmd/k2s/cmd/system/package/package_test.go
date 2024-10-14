// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"path/filepath"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUpgrade(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "package Unit Tests", Label("unit", "ci"))
}

var _ = BeforeSuite(func() {
	PackageCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
})

var _ = Describe("package", func() {
	Describe("buildSystemPackageCmd", func() {
		When("flags set", func() {
			It("creates the command", func() {
				flags := PackageCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(ControlPlaneCPUsFlagName, "6")
				flags.Set(ControlPlaneMemoryFlagName, "4GB")
				flags.Set(ControlPlaneDiskSizeFlagName, "50GB")
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(ProxyFlagName, "http://myproxy:81")
				flags.Set(ForOfflineInstallationFlagName, "true")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ConsistOf(" -ShowLogs", " -Proxy http://myproxy:81", " -VMProcessorCount 6", " -VMMemoryStartupBytes 4GB", " -VMDiskSize 50GB", " -TargetDirectory 'dir'", " -ZipPackageFileName 'file.zip'", " -ForOfflineInstallation"))
			})
		})
	})
})
