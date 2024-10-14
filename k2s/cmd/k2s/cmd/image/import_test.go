// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package image

import (
	"path/filepath"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("import", Ordered, func() {
	BeforeAll(func() {
		importCmd.Flags().BoolP(common.OutputFlagName, common.OutputFlagShorthand, false, common.OutputFlagUsage)
	})
	Describe("buildImportCmd", func() {
		BeforeEach(func() {
			resetImportFlags()

			DeferCleanup(resetImportFlags)
		})

		Context("with tar archieve", func() {
			It("returns correct import command", func() {
				importCmd.Flags().Set(tarFlag, "myImage")

				cmd, params, err := buildImportPsCmd(importCmd, false)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Import-Image.ps1") + "'"))
				Expect(params).To(ConsistOf(" -ImagePath 'myImage'"))
			})
		})

		Context("with directory", func() {
			It("returns correct import command", func() {
				importCmd.Flags().Set(dirFlag, "myDir")

				cmd, params, err := buildImportPsCmd(importCmd, false)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Import-Image.ps1") + "'"))
				Expect(params).To(ConsistOf(" -ImageDir 'myDir'"))
			})
		})

		Context("with tar archieve and directory", func() {
			It("returns correct import command", func() {
				importCmd.Flags().Set(tarFlag, "myImage")
				importCmd.Flags().Set(dirFlag, "myDir")

				cmd, params, err := buildImportPsCmd(importCmd, false)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Import-Image.ps1") + "'"))
				Expect(params).To(ConsistOf(" -ImagePath 'myImage'"))
			})
		})

		Context("without tar archieve and without directory", func() {
			It("returns error", func() {
				cmd, params, err := buildImportPsCmd(importCmd, false)

				Expect(err).To(MatchError("no path to oci archive provided"))
				Expect(cmd).To(BeEmpty())
				Expect(params).To(BeNil())
			})
		})

		Context("with all flags", func() {
			It("returns correct import command", func() {
				importCmd.Flags().Set(tarFlag, "myImage")
				importCmd.Flags().Set(dockerArchiveFlag, "true")

				cmd, params, err := buildImportPsCmd(importCmd, true)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + filepath.Join(utils.InstallDir(), "lib", "scripts", "k2s", "image", "Import-Image.ps1") + "'"))
				Expect(params).To(ConsistOf(" -ImagePath 'myImage'", " -Windows", " -DockerArchive"))
			})
		})
	})
})

func resetImportFlags() {
	importCmd.Flags().Set(tarFlag, "")
	importCmd.Flags().Set(dirFlag, "")
	importCmd.Flags().Set(windowsFlag, "")
	importCmd.Flags().Set(dockerArchiveFlag, "")
}
