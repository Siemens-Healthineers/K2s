// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package host

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
)

type StdWriter interface {
	WriteStdOut(message string)
	WriteStdErr(message string)
	Flush()
}

// TODO: extract to e.g. OS package?
type CmdExecutor struct {
	stdWriter StdWriter
	ctx       context.Context
}

// SystemDrive returns hard-coded 'C:\' drive string instead of the actual system drive, because some containers are also hard-coded to this drive.
//
// Note: This string has already the backslash '\' attached, because Go's filepath.Join() would otherwise not be able to correctly join the drive and other path components
// (see https://github.com/golang/go/issues/26953).
func SystemDrive() string {
	return "C:\\"
}

func CreateDirIfNotExisting(path string) error {
	if PathExists(path) {
		return nil
	}
	slog.Debug("Dir not existing, creating it", "path", path)

	if err := os.MkdirAll(path, os.ModePerm); err != nil {
		return fmt.Errorf("could not create directory '%s': %w", path, err)
	}
	return nil
}

func ExecutableDir() (string, error) {
	exePath, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("could not determine executable: %w", err)
	}
	return filepath.Dir(exePath), nil
}

func PathExists(path string) bool {
	_, err := os.Stat(path)
	if err == nil {
		slog.Debug("Path exists", "path", path)
		return true
	}

	if !errors.Is(err, fs.ErrNotExist) {
		slog.Error("could not check existence of path", "path", path, "error", err)
	}
	return false
}

func RemovePaths(paths ...string) error {
	slog.Debug("Deleting paths", "paths", paths)

	for _, path := range paths {
		if err := os.Remove(path); err != nil {
			return fmt.Errorf("could not remove '%s': %w", path, err)
		}
		slog.Debug("Path removed", "path", path)
	}
	return nil
}

func AppendToFile(path string, text string) error {
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, os.ModePerm)
	if err != nil {
		return fmt.Errorf("could not open file '%s': %w", path, err)
	}
	defer func() {
		if err := file.Close(); err != nil {
			slog.Error("could not close file", "path", path, "error", err)
		}
	}()

	if _, err = file.WriteString(text); err != nil {
		return fmt.Errorf("could not write to file '%s': %w", path, err)
	}
	return nil
}

func NewCmdExecutor(stdWriter StdWriter) *CmdExecutor {
	return &CmdExecutor{stdWriter: stdWriter}
}

func (exe *CmdExecutor) WithContext(ctx context.Context) *CmdExecutor {
	exe.ctx = ctx
	return exe
}

func (exe *CmdExecutor) ExecuteCmd(name string, arg ...string) error {
	var cmd *exec.Cmd
	if exe.ctx == nil {
		cmd = exec.Command(name, arg...)
	} else {
		cmd = exec.CommandContext(exe.ctx, name, arg...)
	}

	cmd.Stdin = os.Stdin
	stdOut, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}

	stdErr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}

	stdOutChan := make(chan string)
	stdErrChan := make(chan string)

	go readStream(stdOut, stdOutChan)
	go readStream(stdErr, stdErrChan)

	if err := cmd.Start(); err != nil {
		return fmt.Errorf("command could not be started: %w", err)
	}

	slog.Debug("Command started")

	for stdOutChan != nil || stdErrChan != nil {
		select {
		case errMsg, ok := <-stdErrChan:
			if !ok {
				stdErrChan = nil

				slog.Debug("Channel closed", "channel", "stderr")
				continue
			}
			exe.stdWriter.WriteStdErr(errMsg)
		case stdMsg, ok := <-stdOutChan:
			if !ok {
				stdOutChan = nil

				slog.Debug("Channel closed", "channel", "stdout")
				continue
			}
			exe.stdWriter.WriteStdOut(stdMsg)
		}
	}

	exe.stdWriter.Flush()

	slog.Debug("Waiting for command to finish")

	if err := cmd.Wait(); err != nil {
		return fmt.Errorf("command failed: %w", err)
	}

	slog.Debug("Command finished")

	return nil
}

func readStream(stream io.ReadCloser, dataReceived chan string) {
	defer close(dataReceived)

	slog.Debug("routine started", "routine", "readStream")

	scanner := bufio.NewScanner(stream)

	for scanner.Scan() {
		dataReceived <- scanner.Text()
	}

	slog.Debug("routine finished", "routine", "readStream")
}
