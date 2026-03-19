// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package nodepackage

import (
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/spf13/cobra"
)

func TestNodePackage(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node-package Unit Tests", Label("unit", "ci"))
}

// helper: create a cobra command with all node-package flags registered.
func newTestCmd() *cobra.Command {
	cmd := &cobra.Command{Use: "test"}
	RegisterFlags(cmd)
	return cmd
}

var _ = Describe("nodepackage", func() {

	Describe("IsSet", func() {
		It("returns false when flag is not set", func() {
			cmd := newTestCmd()
			Expect(IsSet(cmd.Flags())).To(BeFalse())
		})

		It("returns true when --node-package is set", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(NodePackageFlagName, "true")
			Expect(IsSet(cmd.Flags())).To(BeTrue())
		})
	})

	Describe("Validate", func() {
		var supportedOS = []string{"debian12", "debian13"}

		It("returns error when --os is missing", func() {
			cmd := newTestCmd()

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("--os"))
			Expect(err.Error()).To(ContainSubstring("--node-package"))
		})

		It("returns nil when --os is a supported value", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian12")

			Expect(Validate(cmd.Flags(), supportedOS)).To(Succeed())
		})

		It("returns error when --os value is not in the supported list", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "ubuntu22")

			err := Validate(cmd.Flags(), supportedOS)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(ContainSubstring("ubuntu22"))
			Expect(err.Error()).To(ContainSubstring("debian12"))
		})
	})

	Describe("BuildCmd", func() {
		When("target-dir is missing", func() {
			It("returns an error", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, _, err := BuildCmd(cmd.Flags(), false, "", "debian12-node.zip", "")
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("target-dir"))
			})
		})

		When("name is missing", func() {
			It("returns an error", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, _, err := BuildCmd(cmd.Flags(), false, "C:\\output", "", "")
				Expect(err).To(HaveOccurred())
				Expect(err.Error()).To(ContainSubstring("name"))
			})
		})

		When("debian12", func() {
			It("routes to New-K2sNodePackage.ps1 with correct params", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				script, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(script).To(ContainSubstring(filepath.Join("lib", "scripts", "k2s", "system", "package", "New-K2sNodePackage.ps1")))
				Expect(params).To(ContainElement(" -TargetDirectory 'C:\\output'"))
				Expect(params).To(ContainElement(" -ZipPackageFileName 'debian12-node.zip'"))
				Expect(params).To(ContainElement(" -OS 'debian12'"))
			})
		})

		When("debian13", func() {
			It("builds params for debian13", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian13")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian13-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -OS 'debian13'"))
			})
		})

		When("proxy is provided", func() {
			It("includes -Proxy param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "http://proxy:8080")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -Proxy http://proxy:8080"))
			})
		})

		When("proxy is empty", func() {
			It("does not include -Proxy param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				for _, p := range params {
					Expect(p).ToNot(ContainSubstring("Proxy"))
				}
			})
		})

		When("ShowLogs is requested", func() {
			It("includes -ShowLogs param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), true, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				Expect(params).To(ContainElement(" -ShowLogs"))
			})
		})

		When("ShowLogs is not requested", func() {
			It("does not include -ShowLogs param", func() {
				cmd := newTestCmd()
				cmd.Flags().Set(OSFlagName, "debian12")

				_, params, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
				Expect(err).ToNot(HaveOccurred())
				for _, p := range params {
					Expect(p).ToNot(ContainSubstring("ShowLogs"))
				}
			})
		})

		It("does not route to full-package or delta-package scripts", func() {
			cmd := newTestCmd()
			cmd.Flags().Set(OSFlagName, "debian12")

			script, _, err := BuildCmd(cmd.Flags(), false, "C:\\output", "debian12-node.zip", "")
			Expect(err).ToNot(HaveOccurred())
			Expect(script).ToNot(ContainSubstring("New-K2sPackage.ps1"))
			Expect(script).ToNot(ContainSubstring("New-K2sDeltaPackage.ps1"))
		})
	})
})
