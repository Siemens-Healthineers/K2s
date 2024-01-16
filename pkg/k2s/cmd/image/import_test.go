// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	p "k2s/cmd/params"
	"k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("import", Ordered, func() {
	BeforeAll(func() {
		importCmd.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)
	})
	Describe("buildImportCmd", func() {
		BeforeEach(func() {
			resetImportFlags()

			DeferCleanup(resetImportFlags)
		})

		Context("with tar archieve", func() {
			It("returns correct import command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ImportImage.ps1' -ImagePath 'myImage'"
				importCmd.Flags().Set(tarLabel, "myImage")

				actual, err := buildImportCmd(importCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("with directory", func() {
			It("returns correct import command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ImportImage.ps1' -ImageDir 'myDir'"
				importCmd.Flags().Set(directoryLabel, "myDir")

				actual, err := buildImportCmd(importCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("with tar archieve and directory", func() {
			It("returns correct import command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ImportImage.ps1' -ImagePath 'myImage'"
				importCmd.Flags().Set(tarLabel, "myImage")
				importCmd.Flags().Set(directoryLabel, "myDir")

				actual, err := buildImportCmd(importCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		Context("without tar archieve and without directory", func() {
			It("returns error", func() {
				actual, err := buildImportCmd(importCmd)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError("no path to oci archive provided"))
			})
		})

		Context("with all flags", func() {
			It("returns correct import command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ImportImage.ps1' -ImagePath 'myImage' -Windows -DockerArchive"
				importCmd.Flags().Set(tarLabel, "myImage")
				importCmd.Flags().Set(windowsFlag, "true")
				importCmd.Flags().Set(dockerArchiveFlag, "true")

				actual, err := buildImportCmd(importCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})
	})
})

func resetImportFlags() {
	importCmd.Flags().Set(tarLabel, "")
	importCmd.Flags().Set(directoryLabel, "")
	importCmd.Flags().Set(windowsFlag, "")
	importCmd.Flags().Set(dockerArchiveFlag, "")
}
