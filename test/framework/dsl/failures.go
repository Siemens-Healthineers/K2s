// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"github.com/siemens-healthineers/k2s/internal/cli"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

func (cmdResult *K2sCmdResult) VerifyWrongK8sContextFailure() {
	Expect(cmdResult.exitCode).To(Equal(cli.ExitCodeFailure))
	Expect(cmdResult.output).To(SatisfyAll(
		ContainSubstring("WARNING"),
		ContainSubstring("operation requires the K8s context"),
	))
}

func (cmdResult *K2sCmdResult) ExpectSuccess() {
	Expect(cmdResult.exitCode).To(Equal(cli.ExitCodeSuccess), "Expected command to succeed but got exit code %d. Output: %s", cmdResult.exitCode, cmdResult.output)
}

func (cmdResult *K2sCmdResult) VerifySystemNotRunningFailure() {
	Expect(cmdResult.exitCode).To(Equal(cli.ExitCodeFailure))
	Expect(cmdResult.output).To(SatisfyAll(
		ContainSubstring("WARNING"),
		ContainSubstring("not running"),
	))
}

func (cmdResult *K2sCmdResult) VerifyFunctionalityNotAvailableFailure() {
	Expect(cmdResult.exitCode).To(Equal(cli.ExitCodeFailure))
	Expect(cmdResult.output).To(SatisfyAll(
		ContainSubstring("WARNING"),
		ContainSubstring("functionality is not available"),
	))
}
