// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	"github.com/siemens-healthineers/k2s/test/framework/k2s"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

func (cmdResult *K2sCmdResult) VerifyFailureDueToWrongK8sContext() {
	Expect(cmdResult.exitCode).To(Equal(k2s.ExitCodeFailure))
	Expect(cmdResult.output).To(SatisfyAll(
		ContainSubstring("WARNING"),
		ContainSubstring("operation requires the K8s context"),
	))
}
