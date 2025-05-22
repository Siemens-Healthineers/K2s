// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"log"
	"net/http"
	"path/filepath"
	"syscall"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ve "github.com/siemens-healthineers/k2s/internal/version"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/siemens-healthineers/k2s/internal/powershell"
)

const cliName = "httpproxy"

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
	systemPackageCommand, params, err := buildSystemShutdownCmd()
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
	return nil
}

func systemStartupCmd() error {
	// Build cmd and execute it
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
	return nil
}

// Handler function for console control events
func consoleCtrlHandler(ctrlType uint32) uintptr {
	switch ctrlType {
	case CTRL_CLOSE_EVENT:
		log.Println("Console close event received. Attempting cleanup.")
		// Perform cleanup tasks here
		// time.Sleep(2 * time.Second)
		log.Println("Cleanup finished.")
		return 1 // Indicate that the event was handled
	case CTRL_SHUTDOWN_EVENT:
		log.Println("Shutdown event received. Attempting cleanup.")
		// Perform cleanup tasks here
		systemShutdownCmd()
		log.Println("Cleanup finished.")
		return 1 // Indicate that the event was handled
	case CTRL_C_EVENT:
		log.Println("Ctrl+C received. Attempting cleanup.")
		// Perform cleanup tasks here
		log.Println("Cleanup finished.")
		return 1 // Indicate that the event was handled
	case CTRL_BREAK_EVENT:
		log.Println("Ctrl+Break received. Attempting cleanup.")
		// Perform cleanup tasks here
		log.Println("Cleanup finished.")
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
	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)

	proxyHandler := newProxyHttpHandler(proxyConfig)

	log.Fatal(http.ListenAndServe(*proxyConfig.ListenAddress, proxyHandler))
}
