// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

const proxyExecutable = "linkerd2-proxy.exe"
const bootstrapOnlyEnvironment = "LINKERD2_PROXY_IDENTITY_BOOTSTRAP_ONLY"

var executablePath = os.Executable

var commandRunner = func(name string, args ...string) *exec.Cmd {
	return exec.Command(name, args...)
}

func main() {
	if err := run(os.Args[1:], os.Getenv, os.Stdin, os.Stdout, os.Stderr); err != nil {
		fmt.Fprintf(os.Stderr, "[LinkerdProxyIdentity] ERROR: %v\n", err)
		os.Exit(exitCode(err))
	}
}

func run(args []string, getenv func(string) string, stdin, stdout, stderr *os.File) error {
	identityDir := normalizeIdentityDir(getenv("LINKERD2_PROXY_IDENTITY_DIR"), getenv("SystemDrive"), runtime.GOOS == "windows")
	localName := getenv("LINKERD2_PROXY_IDENTITY_LOCAL_NAME")
	trustAnchors := getenv("LINKERD2_PROXY_IDENTITY_TRUST_ANCHORS")

	if err := bootstrapIdentity(identityDir, localName, trustAnchors); err != nil {
		return err
	}
	if getenv(bootstrapOnlyEnvironment) == "1" {
		return nil
	}

	identityExecutable, err := executablePath()
	if err != nil {
		return fmt.Errorf("resolve proxy identity executable path: %w", err)
	}
	proxy := commandRunner(filepath.Join(filepath.Dir(identityExecutable), proxyExecutable), args...)
	proxy.Env = identityEnvironment(identityDir)
	proxy.Stdin = stdin
	proxy.Stdout = stdout
	proxy.Stderr = stderr
	if err := proxy.Run(); err != nil {
		return err
	}
	return nil
}

func normalizeIdentityDir(identityDir, systemDrive string, isWindows bool) string {
	if !isWindows || !strings.HasPrefix(identityDir, "/") || strings.HasPrefix(identityDir, "//") {
		return identityDir
	}
	if systemDrive == "" {
		systemDrive = "C:"
	}
	systemDrive = strings.TrimRight(systemDrive, `\\/`)
	return filepath.FromSlash(systemDrive + identityDir)
}

func identityEnvironment(identityDir string) []string {
	environment := make([]string, 0, len(os.Environ())+1)
	for _, value := range os.Environ() {
		if !strings.HasPrefix(value, "LINKERD2_PROXY_IDENTITY_DIR=") {
			environment = append(environment, value)
		}
	}
	return append(environment, "LINKERD2_PROXY_IDENTITY_DIR="+identityDir)
}

func exitCode(err error) int {
	var exitError *exec.ExitError
	if errors.As(err, &exitError) {
		return exitError.ExitCode()
	}
	return 1
}
