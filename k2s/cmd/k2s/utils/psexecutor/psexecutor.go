// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package psexecutor

import (
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"os/exec"
	"time"

	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"

	"github.com/siemens-healthineers/k2s/internal/logging"

	"github.com/go-cmd/cmd"
	"github.com/pterm/pterm"
)

func ExecutePowershellScript(script string, psVersion powershell.PowerShellVersion) (time.Duration, error) {
	if psVersion == "" {
		return 0, errors.New("PowerShell version not specified")
	}

	psCmd := powershell.Ps5CmdName
	cmdArg := ""
	if psVersion == powershell.PowerShellV7 {
		psCmd = powershell.Ps7CmdName
		cmdArg = "-Command"

		slog.Info("Switching to PowerShell 7 command syntax")

		if err := powershell.AssertPowerShellV7Installed(); err != nil {
			return 0, err
		}
	}

	cmdOptions := cmd.Options{
		Buffered:   false,
		Streaming:  true,
		BeforeExec: []func(cmd *exec.Cmd){setStdin},
	}

	wrapperScript := prepareExecScript(script)
	cmdRun := cmd.NewCmdOptions(cmdOptions, string(psCmd), cmdArg, wrapperScript)
	doneChan := make(chan struct{})
	errorLineBuffer, err := logging.NewLogBuffer(logging.BufferConfig{
		Limit: 100,
		FlushFunc: func(buffer []string) {
			slog.Error("Flushing error lines", "count", len(buffer), "lines", buffer)
		},
	})
	if err != nil {
		return 0, err
	}

	go readStdChannels(cmdRun, doneChan, errorLineBuffer.Log)

	statusChan := cmdRun.Start()
	finalStatus := <-statusChan
	<-doneChan

	errorLineBuffer.Flush()

	if finalStatus.Exit != 0 {
		return 0, fmt.Errorf("command execution failed, see log output above. Error: exit code %d", finalStatus.Exit)
	}

	seconds := math.Round(finalStatus.Runtime)
	duration := time.Second * time.Duration(int(seconds))

	return duration, nil
}

// TODO: merge/consolidate with k2s\internal\powershell\exec.go
func readStdChannels(cmdRun *cmd.Cmd, doneChan chan struct{}, logErrFunc func(line string)) {
	defer close(doneChan)

	// Done when both channels have been closed
	// https://dave.cheney.net/2013/04/30/curious-channels
	for cmdRun.Stdout != nil || cmdRun.Stderr != nil {
		select {
		case line, open := <-cmdRun.Stdout:
			if !open {
				cmdRun.Stdout = nil
				continue
			}
			if len(line) > 0 {
				pterm.Printfln("⏳ %s", line)
			}
		case line, open := <-cmdRun.Stderr:
			if !open {
				cmdRun.Stderr = nil
				continue
			}
			if len(line) > 0 {
				logErrFunc(line)
				pterm.Printfln("⏳ %s", pterm.Yellow(line))
			}
		}
	}
}

func setStdin(cmd *exec.Cmd) {
	cmd.Stdin = os.Stdin
}

func prepareExecScript(script string) string {
	slog.Debug("Execution script", "script", script)
	wrapperScript := ""

	wrapperScript = ("&'" + utils.InstallDir() + "\\lib\\scripts\\k2s\\base\\" + "Invoke-ExecScript.ps1' -Script ")
	wrapperScript += utils.EscapeWithDoubleQuotes(script)

	slog.Debug("Final execution script", "script", wrapperScript)

	return wrapperScript
}
