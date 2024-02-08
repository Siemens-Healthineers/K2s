// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package image

import (
	p "k2s/cmd/params"
	"k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("export", Ordered, func() {
	BeforeAll(func() {
		exportCmd.Flags().BoolP(p.OutputFlagName, p.OutputFlagShorthand, false, p.OutputFlagUsage)
	})
	Describe("buildExportCmd", func() {
		BeforeEach(func() {
			resetExportFlags()

			DeferCleanup(resetExportFlags)
		})

		When("no Docker archive flag", func() {
			It("returns correct command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ExportImage.ps1' -Id 'myImageId' -Name 'myImageName' -ExportPath 'myExportPath'"
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")
				exportCmd.Flags().Set(tarLabel, "myExportPath")

				actual, err := buildExportCmd(exportCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("with Docker archive flag", func() {
			It("returns correct command", func() {
				expected := "&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ExportImage.ps1' -Id 'myImageId' -Name 'myImageName' -ExportPath 'myExportPath' -DockerArchive"
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")
				exportCmd.Flags().Set(tarLabel, "myExportPath")
				exportCmd.Flags().Set(dockerArchiveFlag, "true")

				actual, err := buildExportCmd(exportCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).To(Equal(expected))
			})
		})

		When("neither name nor id provided", func() {
			It("returns error", func() {
				exportCmd.Flags().Set(tarLabel, "myExportPath")
				exportCmd.Flags().Set(dockerArchiveFlag, "true")

				actual, err := buildExportCmd(exportCmd)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError("no image id or image name provided"))
			})
		})

		When("no export path provided", func() {
			It("returns error", func() {
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")

				actual, err := buildExportCmd(exportCmd)

				Expect(actual).To(BeEmpty())
				Expect(err).To(MatchError("no export path provided"))
			})
		})
	})
})

func resetExportFlags() {
	exportCmd.Flags().Set(removeImgNameFlagName, "")
	exportCmd.Flags().Set(imageIdFlagName, "")
	exportCmd.Flags().Set(tarLabel, "")
	exportCmd.Flags().Set(dockerArchiveFlag, "")
}
