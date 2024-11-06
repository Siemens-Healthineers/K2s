// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package copy

import (
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path/filepath"

	"github.com/pkg/sftp"
)

type CopyDirection int

type CopyOptions struct {
	Source    string
	Target    string
	Direction CopyDirection
}

type RemoteDir struct {
	Path string
	Join func(remoteDir, relativePath string) string
}

const (
	CopyToNode CopyDirection = iota
	CopyToHost CopyDirection = iota
)

func CopyFileToRemote(localPath, remotePath string, sftpClient *sftp.Client) error {
	slog.Debug("Copying file to remote", "local", localPath, "remote", remotePath)

	remoteFile, err := sftpClient.Create(remotePath)
	if err != nil {
		return fmt.Errorf("failed to create/open remote file '%s': %w", remotePath, err)
	}
	defer func() {
		if err := remoteFile.Close(); err != nil {
			slog.Error("failed to close remote file", "error", err, "path", remotePath)
		}
	}()

	localFile, err := os.Open(localPath)
	if err != nil {
		return fmt.Errorf("failed to open local file '%s': %w", localPath, err)
	}
	defer func() {
		if err := localFile.Close(); err != nil {
			slog.Error("failed to close local file", "error", err, "path", localPath)
		}
	}()

	bytesCopied, err := io.Copy(remoteFile, localFile)
	if err != nil {
		return fmt.Errorf("failed to copy '%s' to '%s': %w", localPath, remotePath, err)
	}
	slog.Debug("Copied file to remote", "local", localPath, "remote", remotePath, "bytes", bytesCopied)
	return nil
}

func CopyFileToLocal(remotePath, localPath string, sftpClient *sftp.Client) error {
	slog.Debug("Copying file to local", "local", localPath, "remote", remotePath)

	remoteFile, err := sftpClient.Open(remotePath)
	if err != nil {
		return fmt.Errorf("failed to open remote file '%s': %w", remotePath, err)
	}
	defer func() {
		if err := remoteFile.Close(); err != nil {
			slog.Error("failed to close remote file", "error", err, "path", remotePath)
		}
	}()

	localFile, err := os.Create(localPath)
	if err != nil {
		return fmt.Errorf("failed to create/open local file '%s': %w", localPath, err)
	}
	defer func() {
		if err := localFile.Close(); err != nil {
			slog.Error("failed to close local file", "error", err, "path", localPath)
		}
	}()

	bytesCopied, err := io.Copy(localFile, remoteFile)
	if err != nil {
		return fmt.Errorf("failed to copy '%s' to '%s': %w", remotePath, localPath, err)
	}
	slog.Debug("Copied file to local", "local", localPath, "remote", remotePath, "bytes", bytesCopied)
	return nil
}

func CopyDirToRemote(localDir string, remoteDir RemoteDir, sftpClient *sftp.Client) error {
	slog.Debug("Copying dir to remote", "local", localDir, "remote", remoteDir.Path)

	err := filepath.WalkDir(localDir, func(localPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("failed to walk local dir '%s': %w", localDir, err)
		}

		relativePath, err := filepath.Rel(localDir, localPath)
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", localPath, err)
		}

		remotePath := remoteDir.Join(remoteDir.Path, relativePath)

		if d.IsDir() {
			slog.Debug("Creating remote dir", "path", remotePath)

			if err := sftpClient.MkdirAll(remotePath); err != nil {
				return fmt.Errorf("failed to create remote dir '%s': %w", remotePath, err)
			}
			return nil
		}
		return CopyFileToRemote(localPath, remotePath, sftpClient)
	})
	if err != nil {
		return fmt.Errorf("failed to copy dir '%s' to '%s': %w", localDir, remoteDir.Path, err)
	}
	return nil
}

func CopyDirToLocal(remoteDir, localDir string, sftpClient *sftp.Client) error {
	slog.Debug("Copying dir to local", "local", localDir, "remote", remoteDir)

	walker := sftpClient.Walk(remoteDir)

	for walker.Step() {
		if err := walker.Err(); err != nil {
			return fmt.Errorf("failed to walk remote dir '%s': %w", remoteDir, err)
		}

		relativePath, err := filepath.Rel(remoteDir, walker.Path())
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", walker.Path(), err)
		}

		localPath := filepath.Join(localDir, relativePath)

		if walker.Stat().IsDir() {
			slog.Debug("Creating local dir", "path", localPath)

			if err := os.MkdirAll(localPath, os.ModePerm); err != nil {
				return fmt.Errorf("failed to create local dir '%s': %w", localPath, err)
			}
			continue
		}
		if err := CopyFileToLocal(walker.Path(), localPath, sftpClient); err != nil {
			return err
		}
	}
	return nil
}
