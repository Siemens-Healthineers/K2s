// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh

import (
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"

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
			mockProcessExecFunc := func(cmd string) error {
				masterShellWasInvoked = true
				masterShellCmd = cmd

				return nil
			}
			mockCommandExecFunc := func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error {
				cmdWasExecutedOnMaster = true
				return nil
			}
			remoteCmdToBeExecuted := ""
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: masterBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted, powershell.DefaultPsVersions)

			Expect(masterShellWasInvoked).To(Equal(true))
			Expect(masterShellCmd).To(Equal(cmdToStartShellMaster))
			Expect(cmdWasExecutedOnMaster).To(Equal(false))
		})
	})

	When("remote command is provided", func() {
		It("it executes the command on master node", func() {
			masterShellWasInvoked := false
			cmdWasExecutedOnMaster := false
			capturedCmdToBeExecuted := ""
			mockProcessExecFunc := func(cmd string) error {
				masterShellWasInvoked = true
				return nil
			}
			mockCommandExecFunc := func(baseCmd, cmd string, psVersion powershell.PowerShellVersion) error {
				cmdWasExecutedOnMaster = true
				capturedCmdToBeExecuted = baseCmd + "-" + cmd
				return nil
			}
			remoteCmdToBeExecuted := "SomeCommand"
			expectCmdToBeInvoked := utils.FormatScriptFilePath(installDirectoryProviderFuncForTest()+scriptRelPathToExecuteCmdMaster) + "-" + remoteCmdToBeExecuted
			remoteCommandHandler := &remoteCommandHandler{
				baseCommandProvider: masterBaseCommandProvider,
				processExecFunc:     mockProcessExecFunc,
				commandExecFunc:     mockCommandExecFunc,
			}

			remoteCommandHandler.Handle(remoteCmdToBeExecuted, powershell.DefaultPsVersions)

			Expect(masterShellWasInvoked).To(Equal(false))
			Expect(cmdWasExecutedOnMaster).To(Equal(true))
			Expect(capturedCmdToBeExecuted).To(Equal(expectCmdToBeInvoked))
		})
	})
})
