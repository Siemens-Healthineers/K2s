// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"github.com/siemens-healthineers/k2s/test/framework/k2s/cli"

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
