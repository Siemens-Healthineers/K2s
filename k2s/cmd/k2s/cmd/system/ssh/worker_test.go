// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"

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
			capturedCmdToBeExecuted := ""
			mockProcessExecFunc := func(cmd string) error {
				workerShellWasInvoked = true
				workerShellCmd = cmd
				return nil
			}
			mockCommandExecFunc := func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error {
				capturedCmdToBeExecuted = cmd
				return nil
			}
			remoteCmdToBeExecuted := ""
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: workerBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted, powershell.DefaultPsVersions)

			Expect(workerShellWasInvoked).To(Equal(true))
			Expect(workerShellCmd).To(Equal(cmdToStartShellWorker))
			Expect(capturedCmdToBeExecuted).To(Equal("echo Connecting..."))
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
			mockCommandExecFunc := func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error {
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

			remoteCommandHandler.Handle(remoteCmdToBeExecuted, powershell.DefaultPsVersions)

			Expect(workerShellWasInvoked).To(Equal(false))
			Expect(cmdWasExecutedOnWorker).To(Equal(true))
			Expect(capturedCmdToBeExecuted).To(Equal(expectCmdToBeInvoked))
		})
	})
})
