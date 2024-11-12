// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package keygen

import (
	"fmt"
	"log/slog"
	"path/filepath"
	"strings"

	"github.com/siemens-healthineers/k2s/internal/core/users/common"
)

type fileSystem interface {
	PathExists(path string) bool
	AppendToFile(path string, text string) error
	ReadFile(path string) ([]byte, error)
	WriteFile(path string, data []byte) error
}

type sshKeyGen struct {
	exec common.CmdExecutor
	fs   fileSystem
}

const (
	keyType        = "rsa"
	keyBits        = "2048"
	keyPassphrase  = ""
	sshKeyGenExe   = "ssh-keygen.exe"
	knownHostsName = "known_hosts"
	lineSeparator  = "\n"
)

func NewSshKeyGen(cmdExecutor common.CmdExecutor, fileSystem fileSystem) *sshKeyGen {
	return &sshKeyGen{
		exec: cmdExecutor,
		fs:   fileSystem,
	}
}

func (gen *sshKeyGen) CreateKey(outKeyFile string, comment string) error {
	slog.Debug("Creating SSH key", "out-file", outKeyFile, "comment", comment)

	if err := gen.exec.ExecuteCmd(sshKeyGenExe, "-f", outKeyFile, "-t", keyType, "-b", keyBits, "-C", comment, "-N", keyPassphrase); err != nil {
		return fmt.Errorf("could not generate SSH key '%s': %w", outKeyFile, err)
	}
	return nil
}

func (gen *sshKeyGen) FindHostInKnownHosts(host string, sshDir string) (hostEntry string, found bool) {
	path := filepath.Join(sshDir, knownHostsName)

	slog.Debug("Looking for host in known_hosts file", "path", path, "host", host)

	bytes, err := gen.fs.ReadFile(path)
	if err != nil {
		slog.Error("could not read known_hosts", "path", path, "error", err)
		return "", false
	}

	knownHosts := strings.Split(string(bytes), lineSeparator)

	for _, entry := range knownHosts {
		if strings.HasPrefix(entry, host) {
			slog.Debug("Found host in known_hosts", "path", path, "host", host)

			hostEntry = entry + lineSeparator
			found = true
			return
		}
	}

	slog.Debug("Host not found in known_hosts", "path", path, "host", host)
	return
}

func (gen *sshKeyGen) SetHostInKnownHosts(hostEntry string, sshDir string) error {
	knownHostsPath := filepath.Join(sshDir, knownHostsName)

	if gen.fs.PathExists(knownHostsPath) {
		slog.Debug("known_hosts file already existing, adding host")
		if err := gen.addToKnownHosts(knownHostsPath, hostEntry); err != nil {
			return fmt.Errorf("could not add host to known_hosts file: %w", err)
		}
		return nil
	}

	slog.Debug("known_hosts file not existing, creating with host entry")
	if err := gen.createKnownHosts(knownHostsPath, hostEntry); err != nil {
		return fmt.Errorf("could not create known_hosts file with host entry: %w", err)
	}
	return nil
}

func (gen *sshKeyGen) createKnownHosts(path string, entry string) error {
	if err := gen.fs.WriteFile(path, []byte(entry)); err != nil {
		return fmt.Errorf("could not create known_hosts file '%s': %w", path, err)
	}
	return nil
}

func (gen *sshKeyGen) addToKnownHosts(path string, hostEntry string) error {
	if err := gen.removeHostFromKnownHostsIfExisting(path, hostEntry); err != nil {
		return fmt.Errorf("could not remove existing host entry from known hosts: %w", err)
	}

	slog.Debug("Adding host to known_hosts file", "path", path, "host-entry", hostEntry)
	if err := gen.fs.AppendToFile(path, hostEntry); err != nil {
		return fmt.Errorf("could not add host to known_hosts file: %w", err)
	}
	return nil
}

func (gen *sshKeyGen) removeHostFromKnownHostsIfExisting(path string, hostEntry string) error {
	host := strings.Split(hostEntry, " ")[0]

	_, found := gen.FindHostInKnownHosts(host, filepath.Dir(path))

	if found {
		slog.Debug("Host entry already existing, removing it first", "path", path, "host", host)

		if err := gen.exec.ExecuteCmd(sshKeyGenExe, "-f", path, "-R", host); err != nil {
			return fmt.Errorf("could not remove host '%s' from known_hosts file '%s': %w", host, path, err)
		}
	}
	return nil
}
