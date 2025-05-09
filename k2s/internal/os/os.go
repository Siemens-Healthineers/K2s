// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package os

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	bos "os"
	"os/exec"
	"path/filepath"
	"time"
)

type Files []fs.FileInfo
type Paths []string

type StdWriter interface {
	WriteStdOut(message string)
	WriteStdErr(message string)
	Flush()
}

type CmdExecutor struct {
	stdWriter StdWriter
	ctx       context.Context
}

func CreateDirIfNotExisting(path string) error {
	if PathExists(path) {
		return nil
	}
	slog.Debug("Dir not existing, creating it", "path", path)

	if err := bos.MkdirAll(path, bos.ModePerm); err != nil {
		return fmt.Errorf("could not create directory '%s': %w", path, err)
	}
	return nil
}

func ExecutableDir() (string, error) {
	exePath, err := bos.Executable()
	if err != nil {
		return "", fmt.Errorf("could not determine executable: %w", err)
	}
	return filepath.Dir(exePath), nil
}

func PathExists(path string) bool {
	_, err := bos.Stat(path)
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
		if err := bos.Remove(path); err != nil {
			return fmt.Errorf("could not remove '%s': %w", path, err)
		}
		slog.Debug("Path removed", "path", path)
	}
	return nil
}

func AppendToFile(path string, text string) error {
	file, err := bos.OpenFile(path, bos.O_APPEND|bos.O_WRONLY, bos.ModePerm)
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

func CopyFile(source string, target string) error {
	slog.Debug("Copying file", "source-path", source, "target-path", target)

	data, err := bos.ReadFile(source)
	if err != nil {
		return fmt.Errorf("could not read file '%s': %w", source, err)
	}

	if err = bos.WriteFile(target, data, bos.ModePerm); err != nil {
		return fmt.Errorf("could not write file '%s': %w", target, err)
	}
	return nil
}

// FilesInDir returns a list of files in the given directory.
// It does not check sub-directories (no recursion).
func FilesInDir(dir string) (files Files, err error) {
	paths, err := bos.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("could not read directory '%s': %w", dir, err)
	}

	for _, path := range paths {
		if path.IsDir() {
			continue
		}

		file, err := path.Info()
		if err != nil {
			return nil, fmt.Errorf("could not get file info '%s': %w", path.Name(), err)
		}
		files = append(files, file)
	}
	return files, nil
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

	cmd.Stdin = bos.Stdin
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

func (files Files) OlderThan(duration time.Duration) (olderFiles Files) {
	for _, file := range files {
		if time.Since(file.ModTime()) > duration {
			olderFiles = append(olderFiles, file)
		}
	}
	return
}

func (files Files) JoinPathsWith(path string) (paths Paths) {
	for _, file := range files {
		paths = append(paths, filepath.Join(path, file.Name()))
	}
	return
}

func (paths Paths) Remove() error {
	return RemovePaths(paths...)
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
