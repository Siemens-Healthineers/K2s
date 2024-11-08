// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package copy

import (
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"path"
	"path/filepath"

	"github.com/pkg/sftp"
)

type CopyDirection int

type CopyOptions struct {
	Source    string
	Target    string
	Direction CopyDirection
}

type ToRemoteCopier struct {
	client *sftp.Client
}

type FromRemoteCopier struct {
	client *sftp.Client
}

const (
	CopyToNode   CopyDirection = iota
	CopyFromNode CopyDirection = iota
)

func NewToRemoteCopier(client *sftp.Client) *ToRemoteCopier {
	return &ToRemoteCopier{client: client}
}

func NewFromRemoteCopier(client *sftp.Client) *FromRemoteCopier {
	return &FromRemoteCopier{client: client}
}

func (c *ToRemoteCopier) CopyFileToRemote(localPath, remotePath string) error {
	slog.Debug("Copying file to remote", "local", localPath, "remote", remotePath)

	remoteFile, err := c.client.Create(remotePath)
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

func (c *FromRemoteCopier) CopyFileFromRemote(remotePath, localPath string) error {
	slog.Debug("Copying file to local", "local", localPath, "remote", remotePath)

	remoteFile, err := c.client.Open(remotePath)
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

func (c *ToRemoteCopier) CopyDirToRemote(localDir, remoteDir string) error {
	slog.Debug("Copying dir to remote", "local", localDir, "remote", remoteDir)

	err := filepath.WalkDir(localDir, func(localPath string, d fs.DirEntry, err error) error {
		if err != nil {
			return fmt.Errorf("failed to walk local dir '%s': %w", localDir, err)
		}

		localPath = filepath.ToSlash(localPath)

		relativePath, err := filepath.Rel(localDir, localPath)
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", localPath, err)
		}

		remotePath := path.Join(remoteDir, filepath.ToSlash(relativePath))

		if d.IsDir() {
			slog.Debug("Creating remote dir", "path", remotePath)

			if err := c.client.MkdirAll(remotePath); err != nil {
				return fmt.Errorf("failed to create remote dir '%s': %w", remotePath, err)
			}
			return nil
		}
		return c.CopyFileToRemote(localPath, remotePath)
	})
	if err != nil {
		return fmt.Errorf("failed to copy dir '%s' to '%s': %w", localDir, remoteDir, err)
	}
	return nil
}

func (c *FromRemoteCopier) CopyDirFromRemote(remoteDir, localDir string) error {
	slog.Debug("Copying dir to local", "local", localDir, "remote", remoteDir)

	walker := c.client.Walk(remoteDir)

	for walker.Step() {
		if err := walker.Err(); err != nil {
			return fmt.Errorf("failed to walk remote dir '%s': %w", remoteDir, err)
		}

		relativePath, err := filepath.Rel(remoteDir, walker.Path())
		if err != nil {
			return fmt.Errorf("failed to determine relative path of '%s': %w", walker.Path(), err)
		}

		localPath := path.Join(localDir, filepath.ToSlash(relativePath))

		if walker.Stat().IsDir() {
			slog.Debug("Creating local dir", "path", localPath)

			if err := os.MkdirAll(localPath, os.ModePerm); err != nil {
				return fmt.Errorf("failed to create local dir '%s': %w", localPath, err)
			}
			continue
		}
		if err := c.CopyFileFromRemote(walker.Path(), localPath); err != nil {
			return err
		}
	}
	return nil
}
