// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node

import (
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"path"
	"path/filepath"
	"strings"

	bos "os"

	"github.com/pkg/sftp"
	"github.com/siemens-healthineers/k2s/internal/core/node/copy"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	"github.com/siemens-healthineers/k2s/internal/host"
)

type copier interface {
	CopyFile(source, target string) error
	CopyDir(source, target string) error
}

type pathInfo struct {
	path  string
	isDir bool
}

type targetInfo struct {
	pathInfo
	isExisting bool
}

type toNodeCopier struct {
	copier *copy.ToRemoteCopier
}

type fromNodeCopier struct {
	copier *copy.FromRemoteCopier
}

func Copy(copyOptions copy.CopyOptions, connectionOptions ssh.ConnectionOptions) error {
	copyFunc, err := determineCopyFunc(copyOptions)
	if err != nil {
		return fmt.Errorf("failed to determine copy function: %w", err)
	}

	sshClient, err := ssh.Connect(connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to dial SSH: %w", err)
	}
	defer func() {
		slog.Debug("Closing SSH client")
		if err := sshClient.Close(); err != nil {
			slog.Error("failed to close SSH client", "error", err)
		}
	}()

	sftpClient, err := sftp.NewClient(sshClient)
	if err != nil {
		return fmt.Errorf("failed to create SFTP client: %w", err)
	}
	slog.Debug("SFTP client created on top of SSH connection")
	defer func() {
		slog.Debug("Closing SFTP client")
		if err := sftpClient.Close(); err != nil {
			slog.Error("failed to close SFTP client", "error", err)
		}
	}()

	return copyFunc(sftpClient)
}

func Exec(command string, connectionOptions ssh.ConnectionOptions) error {
	sshClient, err := ssh.Connect(connectionOptions)
	if err != nil {
		return fmt.Errorf("failed to dial SSH: %w", err)
	}
	defer func() {
		slog.Debug("Closing SSH client")
		if err := sshClient.Close(); err != nil {
			slog.Error("failed to close SSH client", "error", err)
		}
	}()

	session, err := sshClient.NewSession()
	if err != nil {
		return fmt.Errorf("failed to create SSH session: %w", err)
	}

	session.Stdout = bos.Stdout
	session.Stderr = bos.Stdout

	// Session.Run() implicitly closes the session afterwards
	if err := session.Run(command); err != nil {
		return fmt.Errorf("failed to run command: %w", err)
	}
	return nil
}

func (c toNodeCopier) CopyFile(source, target string) error {
	return c.copier.CopyFileToRemote(source, target)
}

func (c toNodeCopier) CopyDir(source, target string) error {
	return c.copier.CopyDirToRemote(source, target)
}

func (c fromNodeCopier) CopyFile(source, target string) error {
	return c.copier.CopyFileFromRemote(source, target)
}

func (c fromNodeCopier) CopyDir(source, target string) error {
	return c.copier.CopyDirFromRemote(source, target)
}

func determineCopyFunc(copyOptions copy.CopyOptions) (func(*sftp.Client) error, error) {
	slog.Debug("Determining copy function", "copy-direction", copyOptions.Direction)

	switch copyOptions.Direction {
	case copy.CopyToNode:
		source, err := analyzeLocalSource(copyOptions.Source)
		if err != nil {
			return nil, fmt.Errorf("failed to analyze local source '%s': %w", copyOptions.Source, err)
		}

		return func(sftpClient *sftp.Client) error {
			target, err := analyzeRemoteTarget(copyOptions.Target, sftpClient)
			if err != nil {
				return fmt.Errorf("failed to analyze remote target '%s': %w", copyOptions.Target, err)
			}
			copier := &toNodeCopier{copier: copy.NewToRemoteCopier(sftpClient)}

			return copySourceToTarget(*source, *target, copier)
		}, nil
	case copy.CopyFromNode:
		target, err := analyzeLocalTarget(copyOptions.Target)
		if err != nil {
			return nil, fmt.Errorf("failed to analyze local target '%s': %w", copyOptions.Target, err)
		}

		return func(sftpClient *sftp.Client) error {
			source, err := analyzeRemoteSource(copyOptions.Source, sftpClient)
			if err != nil {
				return fmt.Errorf("failed to analyze remote source '%s': %w", copyOptions.Source, err)
			}
			copier := &fromNodeCopier{copier: copy.NewFromRemoteCopier(sftpClient)}

			return copySourceToTarget(*source, *target, copier)
		}, nil
	default:
		return nil, fmt.Errorf("invalid copy direction: %d", copyOptions.Direction)
	}
}

func analyzeLocalSource(path string) (*pathInfo, error) {
	slog.Debug("Analyzing local source", "path", path)

	localPath, err := cleanLocalPath(path)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", path, err)
	}

	slog.Debug("Local path cleaned", "path", localPath)

	info, err := bos.Stat(localPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", localPath)
		}
		return nil, fmt.Errorf("failed to retreive information about source '%s': %w", localPath, err)
	}
	return &pathInfo{
		path:  localPath,
		isDir: info.IsDir(),
	}, nil
}

func analyzeLocalTarget(targetPath string) (*targetInfo, error) {
	slog.Debug("Analyzing local target", "path", targetPath)

	localPath, err := cleanLocalPath(targetPath)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", localPath, err)
	}

	slog.Debug("Local path cleaned", "path", localPath)

	info, err := bos.Stat(localPath)
	if err == nil {
		target := &targetInfo{
			pathInfo: pathInfo{
				path:  localPath,
				isDir: info.IsDir(),
			},
			isExisting: true,
		}

		slog.Debug("Local target existing", "path", target.path, "is-dir", target.isDir)
		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for local target '%s': %w", localPath, err)
	}

	slog.Debug("Local target not existing, checking for parent", "target", localPath)
	return analyzeLocalParent(localPath)
}

func analyzeLocalParent(targetPath string) (*targetInfo, error) {
	parent := path.Dir(targetPath)

	_, err := bos.Stat(parent)
	if err == nil {
		slog.Debug("Local parent existing", "parent", parent)
		return &targetInfo{pathInfo: pathInfo{path: targetPath}}, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("local parent not existing '%s' of target '%s' not existing", parent, targetPath)
	}
	return nil, fmt.Errorf("failed to check for local parent dir '%s': %w", parent, err)
}

func analyzeRemoteTarget(remotePath string, sftpClient *sftp.Client) (*targetInfo, error) {
	slog.Debug("Analyzing remote target", "path", remotePath)

	remotePath, err := cleanRemotePath(remotePath, sftpClient)
	if err != nil {
		return nil, fmt.Errorf("failed to clean remote path '%s': %w", remotePath, err)
	}

	info, err := sftpClient.Stat(remotePath)
	if err == nil {
		target := &targetInfo{
			pathInfo: pathInfo{
				path:  remotePath,
				isDir: info.IsDir(),
			},
			isExisting: true,
		}

		slog.Debug("Remote target existing", "path", target.path, "is-dir", target.isDir)
		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for remote target '%s': %w", remotePath, err)
	}

	slog.Debug("Remote target not existing, checking for parent", "target", remotePath)
	return analyzeRemoteParent(remotePath, sftpClient)
}

func analyzeRemoteParent(targetPath string, sftpClient *sftp.Client) (*targetInfo, error) {
	parent := path.Dir(targetPath)

	_, err := sftpClient.Stat(parent)
	if err == nil {
		slog.Debug("Remote parent existing", "parent", parent)
		return &targetInfo{pathInfo: pathInfo{path: targetPath}}, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("remote parent not existing '%s' of target '%s' not existing", parent, targetPath)
	}
	return nil, fmt.Errorf("failed to check for remote parent dir '%s': %w", parent, err)
}

func analyzeRemoteSource(remotePath string, sftpClient *sftp.Client) (*pathInfo, error) {
	slog.Debug("Analyzing remote source", "path", remotePath)

	remotePath, err := cleanRemotePath(remotePath, sftpClient)
	if err != nil {
		return nil, fmt.Errorf("failed to clean remote path '%s': %w", remotePath, err)
	}

	info, err := sftpClient.Stat(remotePath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", remotePath)
		}
		return nil, fmt.Errorf("failed to retreive information about source '%s': %w", remotePath, err)
	}
	return &pathInfo{
		path:  remotePath,
		isDir: info.IsDir(),
	}, nil
}

func cleanLocalPath(localPath string) (string, error) {
	slog.Debug("Cleaning local path", "path", localPath)

	resolvedPath, err := host.ResolveTildePrefix(localPath)
	if err != nil {
		return "", fmt.Errorf("failed to clean local path '%s': %w", localPath, err)
	}
	return path.Clean(filepath.ToSlash(resolvedPath)), nil
}

func cleanRemotePath(remotePath string, sftpClient *sftp.Client) (string, error) {
	slog.Debug("Cleaning remote path", "path", remotePath)

	remotePath, err := resolveTildePrefix(filepath.ToSlash(remotePath), sftpClient)
	if err != nil {
		return "", fmt.Errorf("failed to resolve tilde prefix in remote path '%s': %w", remotePath, err)
	}

	result := path.Clean(remotePath)

	slog.Debug("Remote path cleaned", "path", remotePath)

	return result, nil
}

func resolveTildePrefix(path string, sftpClient *sftp.Client) (string, error) {
	if !strings.HasPrefix(path, "~") {
		return path, nil
	}

	homeDir, err := sftpClient.Getwd()
	if err != nil {
		return "", fmt.Errorf("failed to determine home dir on node: %w", err)
	}

	if strings.HasPrefix(homeDir, "/home/") {
		slog.Debug("Linux remote home dir detected", "path", homeDir)
	} else {
		slog.Debug("Windows remote home dir detected", "path", homeDir)

		homeDir = strings.TrimPrefix(homeDir, "/")
	}
	return strings.Replace(path, "~", homeDir, 1), nil
}

func copySourceToTarget(source pathInfo, target targetInfo, copier copier) error {
	if source.isDir {
		return copyDir(source.path, target, copier)
	}
	return copyFile(source.path, target, copier)
}

func copyFile(source string, target targetInfo, copier copier) error {
	targetPath := target.path
	if target.isExisting && target.isDir {
		targetPath = path.Join(targetPath, path.Base(source))
	}
	return copier.CopyFile(source, targetPath)
}

func copyDir(source string, target targetInfo, copier copier) error {
	targetPath := target.path

	if target.isExisting {
		if !target.isDir {
			return fmt.Errorf("target '%s' is a file", target.path)
		}
		targetPath = path.Join(targetPath, path.Base(source))
	}
	return copier.CopyDir(source, targetPath)
}
