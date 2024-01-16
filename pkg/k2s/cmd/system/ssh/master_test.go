// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"fmt"
	"k2s/utils"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

var _ = Describe("Ssh command for Master", func() {
	installDirectoryForTest := "C:\\somedir"
	installDirectoryProviderFuncForTest := func() string {
		return installDirectoryForTest
	}

	masterBaseCommandProvider := &masterBaseCommandProvider{
		getInstallDirFunc: installDirectoryProviderFuncForTest,
	}

	When("when no remote command is provided", func() {
		It("it starts a shell from the master node", func() {
			masterShellWasInvoked := false
			masterShellCmd := ""
			cmdWasExecutedOnMaster := false
			mockProcessExecFunc := func(cmd string) {
				masterShellWasInvoked = true
				masterShellCmd = cmd
			}
			mockCommandExecFunc := func(cmd string) {
				cmdWasExecutedOnMaster = true
			}
			remoteCmdToBeExecuted := ""
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: masterBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted)

			Expect(masterShellWasInvoked).To(Equal(true))
			Expect(masterShellCmd).To(Equal(CmdToStartShellMaster))
			Expect(cmdWasExecutedOnMaster).To(Equal(false))
		})
	})

	When("remote command is provided", func() {
		It("it executes the command on master node", func() {
			masterShellWasInvoked := false
			cmdWasExecutedOnMaster := false
			capturedCmdToBeExecuted := ""
			mockProcessExecFunc := func(cmd string) {
				masterShellWasInvoked = true
			}
			mockCommandExecFunc := func(cmd string) {
				cmdWasExecutedOnMaster = true
				capturedCmdToBeExecuted = cmd
			}
			remoteCmdToBeExecuted := "SomeCommand"
			expectCmdToBeInvoked := fmt.Sprintf(cmdExecuteFormat,
				utils.FormatScriptFilePath(installDirectoryProviderFuncForTest()+ScriptRelPathToExecuteCmdMaster),
				remoteCmdToBeExecuted)
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: masterBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted)

			Expect(masterShellWasInvoked).To(Equal(false))
			Expect(cmdWasExecutedOnMaster).To(Equal(true))
			Expect(capturedCmdToBeExecuted).To(Equal(expectCmdToBeInvoked))
		})
	})
})
