// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package version

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestVersion(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "version Unit Tests", Label("unit", "ci"))
}

var _ = Describe("GetVersion", func() {
	Context("When getting the version", func() {

		BeforeEach(func() {
			gitCommit = ""
			gitTreeState = ""
			gitTag = ""
		})

		It("should return a valid Version struct", func() {
			v := GetVersion()
			GinkgoWriter.Println(v.Version)

			Expect(v.Version).NotTo(BeEmpty())
			Expect(v.BuildDate).NotTo(BeEmpty())
			Expect(v.GoVersion).NotTo(BeEmpty())
			Expect(v.Compiler).NotTo(BeEmpty())
			Expect(v.Platform).NotTo(BeEmpty())
		})

		It("should construct a valid version string", func() {
			v := GetVersion()
			GinkgoWriter.Println(v.Version)
			Expect(v.Version).To(MatchRegexp(`^v\d+\.\d+\.\d+(\+\w{7}(\.dirty)?)?$`))
		})

		Context("When gitCommit is valid, tree is dirty", func() {
			BeforeEach(func() {
				gitCommit = "abcdefg12345"
				gitTreeState = "dirty"
			})

			It("should construct a version string with git commit", func() {
				v := GetVersion()
				GinkgoWriter.Println(v.Version)
				Expect(v.Version).To(Equal("v99.99.99+abcdefg.dirty"))
				Expect(v.GitTreeState).To(Equal("dirty"))
			})
		})

		Context("When gitCommit is valid, tree is clean", func() {
			BeforeEach(func() {
				gitCommit = "abcdefg12345"
				gitTreeState = "clean"
			})

			It("should construct a version string with git commit", func() {
				v := GetVersion()
				GinkgoWriter.Println(v.Version)
				Expect(v.Version).To(Equal("v99.99.99+abcdefg"))
				Expect(v.GitTreeState).To(Equal("clean"))
			})
		})

		Context("When gitTag is set, tree is clean", func() {
			BeforeEach(func() {
				gitTreeState = "clean"
				gitCommit = "1.2.3"
				gitTag = "1.2.3"
			})

			It("should construct a version string with .dirty", func() {
				v := GetVersion()
				GinkgoWriter.Println(v.Version)
				Expect(v.Version).To(Equal(gitTag))
			})
		})
	})
})
