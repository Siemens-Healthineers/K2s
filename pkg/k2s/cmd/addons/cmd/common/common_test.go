// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package common

import (
	"k2s/setupinfo"
	"k2s/status"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"k8s.io/klog/v2"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons common Unit Tests", Label("unit", "addons"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("addons", func() {
	Describe("ToError", func() {
		When("system-not-running error", func() {
			It("returns system-not-running error", func() {
				err := AddonCmdError(status.ErrNotRunningMsg)

				result := err.ToError()

				Expect(result).To(Equal(status.ErrNotRunning))
			})
		})

		When("system-not-installed error", func() {
			It("returns system-not-installed error", func() {
				err := AddonCmdError(setupinfo.ErrNotInstalledMsg)

				result := err.ToError()

				Expect(result).To(Equal(setupinfo.ErrNotInstalled))
			})
		})

		When("unknown error", func() {
			It("returns unknown error", func() {
				err := AddonCmdError("oops")

				result := err.ToError()

				Expect(result).To(MatchError(ContainSubstring("oops")))
			})
		})
	})
})
