// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package main

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"
)

func main() {
	// ✅ Force proxy (important for VM)
	os.Setenv("HTTPS_PROXY", "http://172.19.1.1:8181")
	os.Setenv("HTTP_PROXY", "http://172.19.1.1:8181")

	proxyURL, err := url.Parse("http://172.19.1.1:8181")
	if err != nil {
		panic("Invalid proxy URL")
	}

	// ✅ Load system root CAs (Windows root store)
	rootCAs, err := x509.SystemCertPool()
	if err != nil {
		panic("Failed to load system root CA pool")
	}

	tr := &http.Transport{
		Proxy: http.ProxyURL(proxyURL),
		TLSClientConfig: &tls.Config{
			RootCAs: rootCAs, // ✅ This is CRITICAL
		},
	}

	client := &http.Client{
		Transport: tr,
		Timeout:   20 * time.Second,
	}

	resp, err := client.Get("https://google.com")
	if err != nil {
		fmt.Println("❌ REQUEST FAILED:")
		panic(err)
	}
	defer resp.Body.Close()

	fmt.Println("✅ HTTPS Request Successful")
	fmt.Println("TLS Handshake Completed")

	if resp.TLS == nil || len(resp.TLS.PeerCertificates) == 0 {
		fmt.Println("❌ No TLS certificates received")
		return
	}

	cert := resp.TLS.PeerCertificates[0]

	fmt.Println("\n==== TLS CERTIFICATE DETAILS ====")
	fmt.Println("Subject :", cert.Subject)
	fmt.Println("Issuer  :", cert.Issuer)
	fmt.Println("NotBefore:", cert.NotBefore)
	fmt.Println("NotAfter :", cert.NotAfter)
	fmt.Println("================================")
}
