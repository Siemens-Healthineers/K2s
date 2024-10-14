// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	ve "github.com/siemens-healthineers/k2s/internal/version"

	"flag"
	"fmt"
	"os"

	"github.com/siemens-healthineers/k2s/internal/containernetworking"
)

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

	containernetworking.Core()
}
