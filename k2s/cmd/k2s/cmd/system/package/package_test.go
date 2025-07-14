// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package systempackage

import (
	"fmt"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/spf13/cobra"

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
				flags.Set(K8sBinsFlagName, "k8sbins")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ConsistOf(" -ShowLogs", " -Proxy http://myproxy:81", " -VMProcessorCount 6", " -VMMemoryStartupBytes 4GB", " -VMDiskSize 50GB", " -TargetDirectory 'dir'", " -ZipPackageFileName 'file.zip'", " -ForOfflineInstallation", " -K8sBinsPath 'k8sbins'"))
			})
		})

		When("code signing flags set", func() {
			It("creates command with certificate path", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(CertificateFlagName, "C:\\certs\\signing.pfx")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ContainElement(" -CertificatePath 'C:\\certs\\signing.pfx'"))
			})

			It("creates command with create certificate flag", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(CreateCertFlagName, "true")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ContainElement(" -CreateCertificate"))
			})

			It("creates command with both standard and code signing parameters", func() {
				flags := PackageCmd.Flags()
				flags.Set(common.OutputFlagName, "true")
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				flags.Set(ProxyFlagName, "http://proxy:8080")
				flags.Set(ForOfflineInstallationFlagName, "true")
				flags.Set(CertificateFlagName, "signing.pfx")

				cmd, params, err := buildSystemPackageCmd(PackageCmd.Flags())
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				Expect(params).To(ContainElement(" -ShowLogs"))
				Expect(params).To(ContainElement(" -TargetDirectory 'dir'"))
				Expect(params).To(ContainElement(" -ZipPackageFileName 'file.zip'"))
				Expect(params).To(ContainElement(" -Proxy http://proxy:8080"))
				Expect(params).To(ContainElement(" -ForOfflineInstallation"))
				Expect(params).To(ContainElement(" -CertificatePath 'signing.pfx'"))
			})

			It("does not include code signing parameters when not specified", func() {
				flags := PackageCmd.Flags()
				flags.Set(TargetDirectoryFlagName, "dir")
				flags.Set(ZipPackageFileNameFlagName, "file.zip")
				
				// Explicitly ensure code signing flags are not set
				flags.Set(CreateCertFlagName, "false")
				flags.Set(CertificateFlagName, "")

				cmd, params, err := buildSystemPackageCmd(flags)
				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sPackage.ps1")))
				
				// Verify no code signing parameters are included
				for _, param := range params {
					Expect(param).ToNot(ContainSubstring("CertificatePath"))
					Expect(param).ToNot(ContainSubstring("CreateCertificate"))
				}
			})
		})
	})

	Describe("Code signing flag validation", func() {
		var cmd *cobra.Command

		BeforeEach(func() {
			// Create a fresh command for each test to avoid flag conflicts
			cmd = &cobra.Command{}
			cmd.Flags().String(CertificateFlagName, "", CertificateFlagUsage)
			cmd.Flags().Bool(CreateCertFlagName, false, CreateCertFlagUsage)
			
			// Add the PreRunE validation
			cmd.PreRunE = func(cmd *cobra.Command, args []string) error {
				createCert, _ := strconv.ParseBool(cmd.Flags().Lookup(CreateCertFlagName).Value.String())
				certPath := cmd.Flags().Lookup(CertificateFlagName).Value.String()

				if createCert && certPath != "" {
					return fmt.Errorf("--certificate and --create-cert are mutually exclusive")
				}
				return nil
			}
		})

		It("allows no code signing flags", func() {
			err := cmd.PreRunE(cmd, []string{})
			Expect(err).ToNot(HaveOccurred())
		})

		It("allows only certificate path", func() {
			cmd.Flags().Set(CertificateFlagName, "cert.pfx")
			err := cmd.PreRunE(cmd, []string{})
			Expect(err).ToNot(HaveOccurred())
		})

		It("allows only create certificate flag", func() {
			cmd.Flags().Set(CreateCertFlagName, "true")
			err := cmd.PreRunE(cmd, []string{})
			Expect(err).ToNot(HaveOccurred())
		})

		It("rejects both certificate path and create certificate flag", func() {
			cmd.Flags().Set(CertificateFlagName, "cert.pfx")
			cmd.Flags().Set(CreateCertFlagName, "true")
			err := cmd.PreRunE(cmd, []string{})
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("mutually exclusive"))
		})
	})

	Describe("ControlPlaneMemoryFlagUsage", func() {
		It("should contain 'minimum 2GB'", func() {
			Expect(ControlPlaneMemoryFlagUsage).To(ContainSubstring("minimum 2GB"))
		})
	})

	Describe("ControlPlaneDiskSizeFlagUsage", func() {
		It("should contain 'minimum 10GB'", func() {
			Expect(ControlPlaneDiskSizeFlagUsage).To(ContainSubstring("minimum 10GB"))
		})
	})
})
