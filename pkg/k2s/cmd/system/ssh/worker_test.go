// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
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
			mockProcessExecFunc := func(cmd string) error {
				workerShellWasInvoked = true
				workerShellCmd = cmd
				return nil
			}
			mockCommandExecFunc := func(baseCmd, cmd string) error {
				cmdWasExecutedOnWorker = true
				return nil
			}
			remoteCmdToBeExecuted := ""
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: workerBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted)

			Expect(workerShellWasInvoked).To(Equal(true))
			Expect(workerShellCmd).To(Equal(cmdToStartShellWorker))
			Expect(cmdWasExecutedOnWorker).To(Equal(false))
		})
	})

	When("remote command is provided", func() {
		It("it executes the command on worker node", func() {
			workerShellWasInvoked := false
			cmdWasExecutedOnWorker := false
			capturedCmdToBeExecuted := ""
			mockProcessExecFunc := func(cmd string) error {
				workerShellWasInvoked = true
				return nil
			}
			mockCommandExecFunc := func(baseCmd, cmd string) error {
				cmdWasExecutedOnWorker = true
				capturedCmdToBeExecuted = baseCmd + "-" + cmd
				return nil
			}
			remoteCmdToBeExecuted := "SomeCommand"
			expectCmdToBeInvoked := utils.FormatScriptFilePath(installDirectoryProviderFuncForTest()+scriptRelPathToExecuteCmdWorker) + "-" + remoteCmdToBeExecuted
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
