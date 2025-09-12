// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package override

import (
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("override", func() {
	Describe("OverrideCmd", func() {
		It("should have correct command structure", func() {
			Expect(OverrideCmd.Use).To(Equal("override"))
			Expect(OverrideCmd.Short).To(Equal("Override command"))
			Expect(OverrideCmd.Long).To(Equal("Override command is used to override certain settings"))
		})

		It("should have Run function assigned", func() {
			Expect(OverrideCmd.Run).ToNot(BeNil())
		})

		It("should contain all expected subcommands", func() {
			commandNames := make([]string, 0)
			for _, cmd := range OverrideCmd.Commands() {
				commandNames = append(commandNames, cmd.Use)
			}

			Expect(commandNames).To(ContainElements("add", "delete", "ls"))
		})

		It("should have three subcommands", func() {
			Expect(len(OverrideCmd.Commands())).To(Equal(3))
		})
	})
})
