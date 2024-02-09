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
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")
				exportCmd.Flags().Set(tarFlag, "myExportPath")

				cmd, params, err := buildExportPsCmd(exportCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ExportImage.ps1'"))
				Expect(params).To(ConsistOf(" -Id 'myImageId'", " -Name 'myImageName'", " -ExportPath 'myExportPath'"))
			})
		})

		When("with Docker archive flag", func() {
			It("returns correct command", func() {
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")
				exportCmd.Flags().Set(tarFlag, "myExportPath")
				exportCmd.Flags().Set(dockerArchiveFlag, "true")

				cmd, params, err := buildExportPsCmd(exportCmd)

				Expect(err).ToNot(HaveOccurred())
				Expect(cmd).To(Equal("&'" + utils.GetInstallationDirectory() + "\\smallsetup\\helpers\\ExportImage.ps1'"))
				Expect(params).To(ConsistOf(" -Id 'myImageId'", " -Name 'myImageName'", " -ExportPath 'myExportPath'", " -DockerArchive"))
			})
		})

		When("neither name nor id provided", func() {
			It("returns error", func() {
				exportCmd.Flags().Set(tarFlag, "myExportPath")
				exportCmd.Flags().Set(dockerArchiveFlag, "true")

				cmd, params, err := buildExportPsCmd(exportCmd)

				Expect(cmd).To(BeEmpty())
				Expect(params).To(BeNil())
				Expect(err).To(MatchError("no image id or image name provided"))
			})
		})

		When("no export path provided", func() {
			It("returns error", func() {
				exportCmd.Flags().Set(removeImgNameFlagName, "myImageName")
				exportCmd.Flags().Set(imageIdFlagName, "myImageId")

				cmd, params, err := buildExportPsCmd(exportCmd)

				Expect(cmd).To(BeEmpty())
				Expect(params).To(BeNil())
				Expect(err).To(MatchError("no export path provided"))
			})
		})
	})
})

func resetExportFlags() {
	exportCmd.Flags().Set(removeImgNameFlagName, "")
	exportCmd.Flags().Set(imageIdFlagName, "")
	exportCmd.Flags().Set(tarFlag, "")
	exportCmd.Flags().Set(dockerArchiveFlag, "")
}
