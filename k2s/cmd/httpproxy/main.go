// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"flag"
	"log"
	"net/http"

	"github.com/siemens-healthineers/k2s/internal/cli"
	ve "github.com/siemens-healthineers/k2s/internal/version"
)

const cliName = "httpproxy"

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

	proxyConfig := newProxyConfig(verbose, addr, forwardProxy, allowedCIDRs)

	proxyHandler := newProxyHttpHandler(proxyConfig)

	log.Fatal(http.ListenAndServe(*proxyConfig.ListenAddress, proxyHandler))
}
