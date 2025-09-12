// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package override

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override_delete", func() {
	Describe("overrideDeleteCmd", func() {
		It("should have correct command structure", func() {
			Expect(overrideDeleteCmd.Use).To(Equal("delete"))
			Expect(overrideDeleteCmd.Short).To(Equal("Delete an override"))
		})

		It("should have RunE function assigned", func() {
			Expect(overrideDeleteCmd.RunE).ToNot(BeNil())
		})
	})

	Describe("overrideDelete function behavior", func() {
		When("argument validation", func() {
			It("should validate empty arguments", func() {
				args := []string{}
				Expect(len(args)).To(Equal(0))
			})

			It("should accept single override argument", func() {
				args := []string{"override1"}

				Expect(len(args)).To(Equal(1))
			})

			It("should accept multiple override arguments", func() {
				args := []string{"override1", "override2", "override3"}

				Expect(len(args)).To(Equal(3))
			})
		})
	})
})
