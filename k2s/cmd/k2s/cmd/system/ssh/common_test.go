// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"strings"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("getRemoteCommandToExecute", func() {
	When("the command separator -- is not used in the cli", func() {
		It("there is no remote command to execute", func() {
			args := make([]string, 0)
			cmdSeparatorIsNotUsed := -1

			cmdToExecute, err := getRemoteCommandToExecute(cmdSeparatorIsNotUsed, args)

			Expect(err).To(BeNil())
			Expect(cmdToExecute).To(BeEmpty())
		})
	})

	When("the command separator -- is used but no arguments are provided", func() {
		It("it returns an error", func() {
			args := make([]string, 0)
			cmdSeparatorIsUsed := 0

			cmdToExecute, err := getRemoteCommandToExecute(cmdSeparatorIsUsed, args)

			Expect(err).NotTo(BeNil())
			Expect(cmdToExecute).To(BeEmpty())
		})
	})

	When("the arguments are provided without using the command separator --", func() {
		It("It returns an erro", func() {
			remoteCommandToExecute := "SomeCommand"
			args := make([]string, 0)
			args = append(args, remoteCommandToExecute)
			cmdSeparatorIsNotUsed := -1

			cmdToExecute, err := getRemoteCommandToExecute(cmdSeparatorIsNotUsed, args)

			Expect(err).NotTo(BeNil())
			Expect(cmdToExecute).To(BeEmpty())
		})
	})

	When("some command is provided after the command seprator -- ", func() {
		It("Returns the command", func() {
			remoteCommandToExecute := "somecommand someargs"
			args := strings.Split(remoteCommandToExecute, " ")
			cmdSeparatorIsUsed := 0

			cmdToExecute, err := getRemoteCommandToExecute(cmdSeparatorIsUsed, args)

			Expect(err).To(BeNil())
			Expect(cmdToExecute).To(Equal(remoteCommandToExecute))
		})
	})
})
