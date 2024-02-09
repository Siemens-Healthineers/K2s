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
	RunSpecs(t, "cmd common Unit Tests", Label("unit", "cmd"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("common", func() {
	Describe("ToError", func() {
		When("system-not-running error", func() {
			It("returns system-not-running error", func() {
				err := CmdError(status.ErrNotRunningMsg)

				result := err.ToError()

				Expect(result).To(Equal(status.ErrNotRunning))
			})
		})

		When("system-running error", func() {
			It("returns system-running error", func() {
				err := CmdError(status.ErrRunningMsg)

				result := err.ToError()

				Expect(result).To(Equal(status.ErrRunning))
			})
		})

		When("system-not-installed error", func() {
			It("returns system-not-installed error", func() {
				err := CmdError(setupinfo.ErrNotInstalledMsg)

				result := err.ToError()

				Expect(result).To(Equal(setupinfo.ErrNotInstalled))
			})
		})

		When("unknown error", func() {
			It("returns unknown error", func() {
				err := CmdError("oops")

				result := err.ToError()

				Expect(result).To(MatchError(ContainSubstring("oops")))
			})
		})
	})
})
