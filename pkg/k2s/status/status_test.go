// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package status

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"k8s.io/klog/v2"
)

func Test(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status Unit Tests", Label("unit", "status"))
}

var _ = BeforeSuite(func() {
	klog.SetLogger(GinkgoLogr)
})

var _ = Describe("status", func() {
	Describe("IsErrNotRunning", func() {
		When("system-not-running error", func() {
			It("returns true", func() {
				actual := IsErrNotRunning(ErrNotRunningMsg)

				Expect(actual).To(BeTrue())
			})
		})

		When("not system-not-running error", func() {
			It("returns false", func() {
				actual := IsErrNotRunning(ErrRunningMsg)

				Expect(actual).To(BeFalse())
			})
		})
	})

	Describe("IsErrRunning", func() {
		When("system-running error", func() {
			It("returns true", func() {
				actual := IsErrRunning(ErrRunningMsg)

				Expect(actual).To(BeTrue())
			})
		})

		When("not system-running error", func() {
			It("returns false", func() {
				actual := IsErrRunning(ErrNotRunningMsg)

				Expect(actual).To(BeFalse())
			})
		})
	})
})
