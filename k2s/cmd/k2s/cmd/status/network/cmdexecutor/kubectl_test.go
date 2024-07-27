// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package cmdexecutor_test

import (
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	cmdexecutor "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/cmdexecutor"
)

func mockCommandRunner(output []byte, err error) cmdexecutor.CommandRunner {
	return func(name string, arg ...string) ([]byte, error) {
		return output, err
	}
}

func TestCmdExecutorPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cmdexecutor pkg Unit Tests", Label("unit", "ci", "status", "network", "cmdexecutor"))
}

var _ = Describe("Kubectl", func() {
	var (
		kubectl *cmdexecutor.Kubectl
	)

	Describe("ExecCmd", func() {
		It("should execute the command successfully", func() {

			kubectl = cmdexecutor.NewKubectlCliWithRunner("/fake/dir", mockCommandRunner([]byte("success"), nil))

			status := kubectl.ExecCmd("hello")

			Expect(status.Ok).To(BeTrue())
			Expect(status.Output).To(Equal("success"))
			Expect(status.Err).To(BeNil())
		})

		It("should handle command execution failure", func() {
			kubectl = cmdexecutor.NewKubectlCliWithRunner("/fake/dir", mockCommandRunner([]byte("failure"), errors.New("command failed")))
			status := kubectl.ExecCmd("other", "command")

			Expect(status.Ok).To(BeFalse())
			Expect(status.Output).To(Equal("failure"))
			Expect(status.Err).To(MatchError("command failed"))
		})
	})
})
