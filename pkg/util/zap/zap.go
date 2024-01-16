// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

//go:build windows
// +build windows

// Zap.exe helps forcefully delete containerd and docker image storage on windows node.

package main

import (
	ve "base/version"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/Microsoft/hcsshim"
)

const cliName = "zap"

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

func folderExists(path string) bool {
	_, err := os.Stat(path)
	if err == nil {
		return true
	}
	if os.IsNotExist(err) {
		return false
	}
	return true
}

func main() {
	var folder string
	flag.StringVar(&folder, "folder", "", "Folder to zap.")
	version := flag.Bool("version", false, "show the current version of the CLI")
	flag.Parse()

	if *version {
		printCLIVersion()
		os.Exit(0)
	}

	if folder == "" {
		fmt.Println("Error: folder must be supplied")
		return
	}
	if folderExists(folder) {
		location, foldername := filepath.Split(folder)
		info := hcsshim.DriverInfo{
			HomeDir: location,
			Flavour: 0,
		}
		if err := hcsshim.DestroyLayer(info, foldername); err != nil {
			fmt.Println("ERROR: ", err)
		} else {
			fmt.Println("INFO: Zapped successfully")
		}
	} else {
		fmt.Println("ERROR: Folder does not exist")
	}
}
