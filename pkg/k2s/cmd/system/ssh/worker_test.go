// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Ssh command for worker", func() {
	installDirectoryForTest := "C:\\somedir"
	installDirectoryProviderFuncForTest := func() string {
		return installDirectoryForTest
	}

	workerBaseCommandProvider := &workerBaseCommandProvider{
		getInstallDirFunc: installDirectoryProviderFuncForTest,
	}

	When("no remote command is provided", func() {
		It("it starts a shell from the worker node", func() {
			workerShellWasInvoked := false
			workerShellCmd := ""
			cmdWasExecutedOnWorker := false
			mockProcessExecFunc := func(cmd string) {
				workerShellWasInvoked = true
				workerShellCmd = cmd
			}
			mockCommandExecFunc := func(cmd string) {
				cmdWasExecutedOnWorker = true
			}
			remoteCmdToBeExecuted := ""
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: workerBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted)

			Expect(workerShellWasInvoked).To(Equal(true))
			Expect(workerShellCmd).To(Equal(CmdToStartShellWorker))
			Expect(cmdWasExecutedOnWorker).To(Equal(false))
		})
	})

	When("remote command is provided", func() {
		It("it executes the command on worker node", func() {
			workerShellWasInvoked := false
			cmdWasExecutedOnWorker := false
			capturedCmdToBeExecuted := ""
			mockProcessExecFunc := func(cmd string) {
				workerShellWasInvoked = true
			}
			mockCommandExecFunc := func(cmd string) {
				cmdWasExecutedOnWorker = true
				capturedCmdToBeExecuted = cmd
			}
			remoteCmdToBeExecuted := "SomeCommand"
			expectCmdToBeInvoked := fmt.Sprintf(cmdExecuteFormat,
				utils.FormatScriptFilePath(installDirectoryProviderFuncForTest()+ScriptRelPathToExecuteCmdWorker),
				remoteCmdToBeExecuted)
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: workerBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted)

			Expect(workerShellWasInvoked).To(Equal(false))
			Expect(cmdWasExecutedOnWorker).To(Equal(true))
			Expect(capturedCmdToBeExecuted).To(Equal(expectCmdToBeInvoked))
		})
	})
})
