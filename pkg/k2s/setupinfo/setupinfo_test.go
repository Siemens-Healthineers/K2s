// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package setupinfo

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"k8s.io/klog/v2"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "setupinfo Unit Tests", Label("unit", "setupinfo"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("setupinfo", func() {
	Describe("IsErrNotInstalled", func() {
		When("system-not-installed error", func() {
			It("returns true", func() {
				actual := IsErrNotInstalled(string(ErrNotInstalledMsg))

				Expect(actual).To(BeTrue())
			})
		})

		When("not system-not-installed error", func() {
			It("returns false", func() {
				actual := IsErrNotInstalled("some-other-error")

				Expect(actual).To(BeFalse())
			})
		})
	})

	Describe("ToError", func() {
		When("system-not-installed error", func() {
			It("returns system-not-installed error", func() {
				err := SetupError(ErrNotInstalledMsg)

				result := err.ToError()

				Expect(result).To(Equal(ErrNotInstalled))
			})
		})

		When("unknown error", func() {
			It("returns unknown error", func() {
				err := SetupError("oops")

				result := err.ToError()

				Expect(result).To(MatchError(ContainSubstring("oops")))
			})
		})
	})
})
