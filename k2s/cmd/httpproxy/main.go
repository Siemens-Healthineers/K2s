// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"syscall"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ve "github.com/siemens-healthineers/k2s/internal/version"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

const cliName = "httpproxy"

var cleanupWg sync.WaitGroup // WaitGroup to synchronize cleanup tasks

var listener net.Listener

var kernel32 = syscall.NewLazyDLL("kernel32.dll")
var setConsoleCtrlHandler = kernel32.NewProc("SetConsoleCtrlHandler")

// Console control event types
const (
	CTRL_C_EVENT        uint32 = 0
	CTRL_BREAK_EVENT    uint32 = 1
	CTRL_CLOSE_EVENT    uint32 = 2
	CTRL_LOGOFF_EVENT   uint32 = 5 // Not sent to services
	CTRL_SHUTDOWN_EVENT uint32 = 6 // Sent to console apps during system shutdown
)

func buildSystemShutdownCmd() (string, []string, error) {
	params := []string{}
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "..", "lib", "scripts", "k2s", "system", "shutdown", "Stop-System.ps1"))
	params = append(params, " -ShowLogs")
	return systemPackageCommand, params, nil
}

func buildSystemStartupCmd() (string, []string, error) {
	params := []string{}
	systemPackageCommand := utils.FormatScriptFilePath(filepath.Join(utils.InstallDir(), "..", "lib", "scripts", "k2s", "system", "startup", "Start-System.ps1"))
	params = append(params, " -ShowLogs")
	return systemPackageCommand, params, nil
}

func systemShutdownCmd() error {
	// Build cmd and execute it
	slog.Info("Build shutdown cmd and execute it")
	systemPackageCommand, params, err := buildSystemShutdownCmd()
	if err != nil {
		return err
	}
	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		// slog.Error("Shutdown cmd failed", "error", err)
		return err
	}
	if cmdResult.Failure != nil {
		// slog.Error("Shutdown cmd failed", "error", cmdResult.Failure)
		return cmdResult.Failure
	}
	slog.Info("Shutdown cmd finalized")
	return nil
}

func systemStartupCmd() error {
	// Build cmd and execute it
	slog.Info("Build startup cmd and execute it")
	systemPackageCommand, params, err := buildSystemStartupCmd()
	if err != nil {
		return err
	}
	cmdResult, err := powershell.ExecutePsWithStructuredResult[*common.CmdResult](systemPackageCommand, "CmdResult", common.NewPtermWriter(), params...)
	if err != nil {
		return err
	}
	if cmdResult.Failure != nil {
		return cmdResult.Failure
	}
	slog.Info("Startup cmd finalized")
	return nil
}

// Handler function for console control events
func consoleCtrlHandler(ctrlType uint32) uintptr {
	switch ctrlType {
	case CTRL_CLOSE_EVENT:
		slog.Info("Console close event received.")
		return 1 // Indicate that the event was handled
	case CTRL_SHUTDOWN_EVENT:
		cleanupWg.Add(1)
		go func() {
			defer cleanupWg.Done()
			slog.Info("Shutdown event received: Attempting cleanup.")
			systemShutdownCmd()
			slog.Info("Shutdown event received: Cleanup finished.")
		}()
		cleanupWg.Wait()
		if listener != nil {
			listener.Close()
		}
		return 1
	case CTRL_C_EVENT:
		slog.Info("Ctrl+C received.")
		return 1 // Indicate that the event was handled
	case CTRL_BREAK_EVENT:
		slog.Info("Ctrl+Break received.")
		return 1 // Indicate that the event was handled
	}
	return 0 // Indicate that the event was not handled
}

func main() {
	var allowedCIDRs networkCIDRs
	verbose := flag.Bool("verbose", true, "should every proxy request be logged to stdout")
	addr := flag.String("addr", ":8181", "proxy listen address")
	forwardProxy := flag.String("forwardproxy", "", "forward proxy to be used")

	versionFlag := cli.NewVersionFlag(cliName)
	flag.Var(&allowedCIDRs, "allowed-cidr", "network interfaces on which HTTP proxy is available")
	flag.Parse()

	if *versionFlag {
		ve.GetVersion().Print(cliName)
		return
	}

	// Register the handler function
	handler := syscall.NewCallback(consoleCtrlHandler)
	ret, _, err := setConsoleCtrlHandler.Call(handler, 1)
	if ret == 0 {
		log.Fatalf("Error registering console control handler: %v\n", err)
		return
	}
	// Call the system startup command
	systemStartupCmd()

	// start proxy
	slog.Info("Start of proxy.")
	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)
	proxyHandler := newProxyHttpHandler(proxyConfig)

	// Keep a reference to the listener
	listener, err = net.Listen("tcp", *proxyConfig.ListenAddress)
	if err != nil {
		slog.Error("Error starting proxy: %v\n", err)
		return
	}
	http.Serve(listener, proxyHandler)

	// Wait for cleanup tasks before exiting
	slog.Info("Wait for exit of shutdown handler")
	cleanupWg.Wait()

	// flush all logs
	slog.Info("Sync stderr log file")
	os.Stderr.Sync()
}
