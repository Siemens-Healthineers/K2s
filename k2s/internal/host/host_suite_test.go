// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host_test

import (
	"os"
	"path/filepath"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/host"
)

func TestHostPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "host pkg Integration Tests", Label("integration", "host"))
}

var _ = Describe("host pkg", func() {
	Describe("SystemDrive", func() {
		It("returns Windows system drive with trailing backslash", func() {
			drive := host.SystemDrive()

			Expect(drive).To(Equal("C:\\"))
		})
	})
	Describe("CreateDirIfNotExisting", func() {
		var tempDir string

		BeforeEach(func() {
			tempDir = GinkgoT().TempDir()

			GinkgoWriter.Println("Using temp dir:", tempDir)
		})

		Context("dir not existing", func() {
			It("creates the dir", func() {
				dirToCreate := filepath.Join(tempDir, "create", "me")

				_, err := os.Stat(dirToCreate)
				Expect(err).To(MatchError(os.ErrNotExist))

				Expect(host.CreateDirIfNotExisting(dirToCreate)).To(Succeed())

				_, err = os.Stat(dirToCreate)
				Expect(err).ToNot(HaveOccurred())
			})
		})

		Context("dir already existing", func() {
			It("returns without error", func() {
				dirToCreate := filepath.Join(tempDir, "create", "me")

				Expect(os.MkdirAll(dirToCreate, os.ModePerm)).To(Succeed())

				_, err := os.Stat(dirToCreate)
				Expect(err).ToNot(HaveOccurred())

				Expect(host.CreateDirIfNotExisting(dirToCreate)).To(Succeed())
			})
		})
	})

	Describe("ExecutableDir", func() {
		It("returns a directory", func() {
			dir, err := host.ExecutableDir()

			Expect(err).ToNot(HaveOccurred())

			GinkgoWriter.Println("Executable dir:", dir)

			info, err := os.Stat(dir)
			Expect(err).ToNot(HaveOccurred())
			Expect(info.IsDir()).To(BeTrue())
		})
	})
})
