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
	"time"

	bos "os"

	"github.com/pkg/sftp"
	"github.com/siemens-healthineers/k2s/internal/core/node/copy"
	"github.com/siemens-healthineers/k2s/internal/host"
	"golang.org/x/crypto/ssh"
)

type ConnectionOptions struct {
	IpAddress  string
	RemoteUser string
	SshKeyPath string
	Timeout    time.Duration
}

type pathInfo struct {
	path       string
	isExisting bool
	isWindows  bool
}

type localInfo struct {
	pathInfo
	name   string
	isDir  bool
	parent string
}

// TODO: consolidate structs for loca/remote info
type remoteInfo struct {
	name string
	pathInfo
	isDir  bool
	parent string
}

const (
	defaultTcpPort = 22
)

var (
	joinRelWithWinPath   = func(dir, rel string) string { return filepath.Join(dir, rel) }
	joinRelWithLinuxPath = func(dir, rel string) string { return path.Join(dir, filepath.ToSlash(rel)) }
)

func Copy(copyOptions copy.CopyOptions, connectionOptions ConnectionOptions) error {
	copyFunc, err := determineCopyFunc(copyOptions)
	if err != nil {
		return fmt.Errorf("failed to determine copy function: %w", err)
	}

	sshClient, err := connectSsh(connectionOptions)
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
			return copyToNode(*source, *target, sftpClient)
		}, nil
	case copy.CopyToHost:
		target, err := analyzeLocalTarget(copyOptions.Target)
		if err != nil {
			return nil, fmt.Errorf("failed to analyze local target '%s': %w", copyOptions.Target, err)
		}

		return func(sftpClient *sftp.Client) error {
			source, err := analyzeRemoteSource(copyOptions.Source, sftpClient)
			if err != nil {
				return fmt.Errorf("failed to analyze remote source '%s': %w", copyOptions.Source, err)
			}
			return copyToHost(*source, *target, sftpClient)
		}, nil
	default:
		return nil, fmt.Errorf("invalid copy direction: %d", copyOptions.Direction)
	}
}

func analyzeLocalSource(path string) (*localInfo, error) {
	slog.Debug("Analyzing local source", "path", path)

	localPath, err := cleanLocalPath(path)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", path, err)
	}

	info, err := bos.Stat(localPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", localPath)
		}
		return nil, fmt.Errorf("failed to retreive information about source '%s': %w", localPath, err)
	}
	return &localInfo{
		pathInfo: pathInfo{path: localPath, isExisting: true, isWindows: true},
		name:     info.Name(),
		isDir:    info.IsDir(),
	}, nil
}

func analyzeLocalTarget(path string) (*localInfo, error) {
	slog.Debug("Analyzing local target", "path", path)

	localPath, err := cleanLocalPath(path)
	if err != nil {
		return nil, fmt.Errorf("failed to clean local path '%s': %w", path, err)
	}

	target := &localInfo{pathInfo: pathInfo{path: localPath, isWindows: true}, parent: filepath.Dir(localPath)}

	info, err := bos.Stat(localPath)
	if err == nil {
		target.isExisting = true
		target.isDir = info.IsDir()

		slog.Debug("Local target existing", "path", localPath, "is-dir", target.isDir)

		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for local target '%s': %w", target.path, err)
	}

	slog.Debug("Local target not existing, checking for parent", "target", target.path, "parent", target.parent)

	_, err = bos.Stat(target.parent)
	if err == nil {
		slog.Debug("Local parent existing", "parent", target.parent)
		return target, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("local parent not existing '%s' of target '%s' not existing", target.parent, target.path)
	}
	return nil, fmt.Errorf("failed to check for local parent dir '%s': %w", target.parent, err)
}

func analyzeRemoteTarget(remotePath string, sftpClient *sftp.Client) (*remoteInfo, error) {
	slog.Debug("Analyzing remote target", "path", remotePath)

	remoteHomeDir, err := sftpClient.Getwd()
	if err != nil {
		return nil, fmt.Errorf("failed to determine remote home dir: %w", err)
	}

	target := &remoteInfo{}

	remotePath = strings.Replace(remotePath, "~", remoteHomeDir, 1)

	if strings.HasPrefix(remoteHomeDir, "/home/") {
		slog.Debug("Linux remote home dir detected", "path", remoteHomeDir)

		target.path = path.Clean(remotePath)
		target.parent = path.Dir(remotePath)
	} else {
		slog.Debug("Windows remote home dir detected", "path", remoteHomeDir)

		target.isWindows = true

		remotePath = filepath.Clean(remotePath)
		if strings.HasPrefix(remotePath, string(filepath.Separator)) {
			remotePath = remotePath[1:]
		}

		target.path = remotePath
		target.parent = filepath.Dir(remotePath)
	}

	info, err := sftpClient.Stat(target.path)
	if err == nil {
		slog.Debug("Remote target existing", "value", target.path)

		target.isExisting = true
		target.isDir = info.IsDir()

		return target, nil
	}

	if !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("failed to check for remote target '%s': %w", target.path, err)
	}

	slog.Debug("Remote target not existing, checking for parent", "target", target.path, "parent", target.parent)

	_, err = sftpClient.Stat(target.parent)
	if err == nil {
		slog.Debug("Remote parent existing", "parent", target.parent)
		return target, nil
	}
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("remote parent not existing '%s' of target '%s' not existing", target.parent, target.path)
	}
	return nil, fmt.Errorf("failed to check for remote parent dir '%s': %w", target.parent, err)
}

func analyzeRemoteSource(remotePath string, sftpClient *sftp.Client) (*remoteInfo, error) {
	slog.Debug("Analyzing remote source", "path", remotePath)

	remoteHomeDir, err := sftpClient.Getwd()
	if err != nil {
		return nil, fmt.Errorf("failed to determine remote home dir: %w", err)
	}

	source := &remoteInfo{}

	remotePath = strings.Replace(remotePath, "~", remoteHomeDir, 1)

	if strings.HasPrefix(remoteHomeDir, "/home/") {
		slog.Debug("Linux remote home dir detected", "path", remoteHomeDir)

		source.path = path.Clean(remotePath)
		// source.parent = path.Dir(remotePath)
	} else {
		slog.Debug("Windows remote home dir detected", "path", remoteHomeDir)

		source.isWindows = true

		remotePath = filepath.Clean(remotePath)
		if strings.HasPrefix(remotePath, string(filepath.Separator)) {
			remotePath = remotePath[1:]
		}

		source.path = remotePath
		// source.parent = filepath.Dir(remotePath)
	}

	info, err := sftpClient.Stat(source.path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("source '%s' does not exist", source.path)
		}
		return nil, fmt.Errorf("failed to retreive information about source '%s': %w", source.path, err)
	}

	source.isDir = info.IsDir()
	source.isExisting = true
	source.name = info.Name()

	return source, nil
}

func cleanLocalPath(path string) (string, error) {
	if strings.HasPrefix(path, "~") {
		resolvedPath, err := host.ReplaceTildeWithHomeDir(path)
		if err != nil {
			return "", fmt.Errorf("failed to resolve tilde in path '%s': %w", path, err)
		}
		path = resolvedPath
	}
	return filepath.Clean(path), nil
}

func copyToNode(source localInfo, target remoteInfo, sftpClient *sftp.Client) error {
	if source.isDir {
		return copyDirToNode(source, target, sftpClient)
	}
	return copyFileToNode(source, target, sftpClient)
}

func copyFileToNode(source localInfo, target remoteInfo, sftpClient *sftp.Client) error {
	targetPath := target.path
	if target.isExisting && target.isDir {
		targetPath = target.joinWith(source.name)
	}
	return copy.CopyFileToRemote(source.path, targetPath, sftpClient)
}

func copyFileToHost(source remoteInfo, target localInfo, sftpClient *sftp.Client) error {
	targetPath := target.path
	if target.isExisting && target.isDir {
		targetPath = target.joinWith(source.name)
	}
	return copy.CopyFileToLocal(source.path, targetPath, sftpClient)
}

func copyDirToNode(source localInfo, target remoteInfo, sftpClient *sftp.Client) error {
	targetPath := target.path

	if target.isExisting {
		if !target.isDir {
			return fmt.Errorf("target '%s' is a file", target.path)
		}
		targetPath = target.joinWith(source.name)
	}

	targetDir := copy.RemoteDir{Path: targetPath, Join: joinRelWithLinuxPath}
	if target.isWindows {
		targetDir.Join = joinRelWithWinPath
	}
	return copy.CopyDirToRemote(source.path, targetDir, sftpClient)
}

func copyDirToHost(source remoteInfo, target localInfo, sftpClient *sftp.Client) error {
	targetPath := target.path

	if target.isExisting {
		if !target.isDir {
			return fmt.Errorf("target '%s' is a file", target.path)
		}
		targetPath = target.joinWith(source.name)
	}
	return copy.CopyDirToLocal(source.path, targetPath, sftpClient)
}

func copyToHost(source remoteInfo, target localInfo, sftpClient *sftp.Client) error {
	if source.isDir {
		return copyDirToHost(source, target, sftpClient)
	}
	return copyFileToHost(source, target, sftpClient)
}

func connectSsh(options ConnectionOptions) (*ssh.Client, error) {
	slog.Debug("Connecting via SSH", "ip", options.IpAddress, "user", options.RemoteUser, "key", options.SshKeyPath, "timeout", options.Timeout)

	key, err := bos.ReadFile(options.SshKeyPath)
	if err != nil {
		return nil, fmt.Errorf("failed to read private SSH key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("failed to parse private SSH key: %w", err)
	}

	clientConfig := &ssh.ClientConfig{
		User: options.RemoteUser,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         options.Timeout,
	}

	address := fmt.Sprintf("%s:%d", options.IpAddress, defaultTcpPort)
	sshClient, err := ssh.Dial("tcp", address, clientConfig)
	if err != nil {
		return nil, fmt.Errorf("failed to connect via SSH to '%s': %w", address, err)
	}

	slog.Debug("Connected via SSH", "ip", options.IpAddress)
	return sshClient, nil
}

func (info pathInfo) joinWith(elemenToJoin string) string {
	if info.isWindows {
		return filepath.Join(info.path, elemenToJoin)
	}
	return path.Join(info.path, elemenToJoin)
}
