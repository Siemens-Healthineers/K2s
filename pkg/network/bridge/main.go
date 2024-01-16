// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	//"github.com/Microsoft/windows-container-networking/common/core"
	ve "base/version"
	"bridge/common/core"
	"flag"
	"fmt"
	"os"
)

/*
// NetPlugin represents the CNI network plugin.

	type netPlugin struct {
		*cni.Plugin
		nm network.Manager
	}
*/

const cliName = "bridge"

func printCLIVersion() {
	version := ve.GetVersion()
	fmt.Printf("%s: %s\n", cliName, version)

	fmt.Printf("  BuildDate: %s\n", version.BuildDate)
	fmt.Printf("  GitCommit: %s\n", version.GitCommit)
	fmt.Printf("  GitTreeState: %s\n", version.GitTreeState)
	if version.GitTag != "" {
		fmt.Printf("  GitTag: %s\n", version.GitTag)
	}
	fmt.Printf("  GoVersion: %s\n", version.GoVersion)
	fmt.Printf("  Compiler: %s\n", version.Compiler)
	fmt.Printf("  Platform: %s\n", version.Platform)
}

func main() {
	version := flag.Bool("version", false, "show the current version of the CLI")

	flag.Parse()

	if *version {
		printCLIVersion()
		os.Exit(0)
	}

	core.Core()
}
