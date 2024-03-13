// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"

	ve "github.com/siemens-healthineers/k2s/internal/version"
)

const cliName = "httpproxy"

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
	var allowedCIDRs networkCIDRs
	verbose := flag.Bool("verbose", true, "should every proxy request be logged to stdout")
	addr := flag.String("addr", ":8181", "proxy listen address")
	forwardProxy := flag.String("forwardproxy", "", "forward proxy to be used")
	version := flag.Bool("version", false, "show the current version of the CLI")
	flag.Var(&allowedCIDRs, "allowed-cidr", "network interfaces on which HTTP proxy is available")
	flag.Parse()

	if *version {
		printCLIVersion()
		os.Exit(0)
	}

	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)

	proxyHandler := newProxyHttpHandler(proxyConfig)

	log.Fatal(http.ListenAndServe(*proxyConfig.ListenAddress, proxyHandler))

}
