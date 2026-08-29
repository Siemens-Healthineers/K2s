// SPDX-FileCopyrightText: © 2024 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"log"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/cloudflare/cfssl/whitelist"
	"github.com/elazarl/goproxy"
)

func newProxyConfig(verbose *bool, listenAddress *string, forwardProxy *string, allowedCidrs networkCIDRs) *proxyConfig {
	return &proxyConfig{
		VerboseLogging: verbose,
		ListenAddress:  listenAddress,
		ForwardProxy:   forwardProxy,
		AllowedCidrs:   allowedCidrs,
	}
}

func configureForwardProxyInProxyHttpServer(proxy *goproxy.ProxyHttpServer, forwardProxy string) {
	// use the forward transparent proxy
	proxy.Tr.Proxy = func(req *http.Request) (*url.URL, error) {
		return url.Parse(forwardProxy)
	}
	// for SSL conection forwarding is needed
	proxy.ConnectDialWithReq = func(req *http.Request, network string, addr string) (net.Conn, error) {
		if !useProxy(canonicalAddr(req.URL), getenvEitherCase) {
			log.Printf("For request %s don't use proxy", req.URL.String())
			return net.Dial(network, addr)
		}
		log.Printf("For request %s use proxy", req.URL.String())
		return proxy.NewConnectDialToProxy(forwardProxy)(network, addr)
	}
}

func getListenInterfaceWhitelist(allowedNetInterfaces []*net.IPNet) *whitelist.BasicNet {
	wl := whitelist.NewBasicNet()
	for _, interf := range allowedNetInterfaces {
		wl.Add(interf)
	}
	return wl
}

func newProxyHttpHandler(proxyConfig *proxyConfig) http.Handler {
	proxy := goproxy.NewProxyHttpServer()

	//if forward proxy is configured, use it
	if proxyConfig.ForwardProxy != nil && strings.TrimSpace(*proxyConfig.ForwardProxy) != "" {
		log.Printf("Starting httpproxy on %s with forward proxy: %s", *proxyConfig.ListenAddress, *proxyConfig.ForwardProxy)
		configureForwardProxyInProxyHttpServer(proxy, *proxyConfig.ForwardProxy)
	} else {
		log.Printf("Starting httpproxy on %s", *proxyConfig.ListenAddress)
	}

	proxy.Verbose = *proxyConfig.VerboseLogging

	//restrict http proxy access on certain interfaces
	if len(proxyConfig.AllowedCidrs) > 0 {
		log.Printf("Http Proxy available on network interfaces : %s", proxyConfig.AllowedCidrs.String())
		allowedCidrs, _ := proxyConfig.AllowedCidrs.ToIPNet()
		listenInterfaceWhitelist := getListenInterfaceWhitelist(allowedCidrs)
		newProxy, _ := whitelist.NewHandler(proxy, nil, listenInterfaceWhitelist)
		return newProxy
	} else {
		log.Printf("Http Proxy available on ALL network interfaces")
	}

	return proxy
}
