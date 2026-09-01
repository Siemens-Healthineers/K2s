// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"encoding/json"
	"os"
	"path/filepath"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type hnsProxyConfig struct {
	InboundProxyPort       string `json:"inboundproxyport"`
	OutboundProxyPort      string `json:"outboundproxyport"`
	InboundPortExceptions  string `json:"inboundportexceptions"`
	OutboundPortExceptions string `json:"outboundportexceptions"`
}

type k2sConfig struct {
	SmallSetup struct {
		VfpRules struct {
			HnsProxyConfig hnsProxyConfig `json:"hnsproxyconfig"`
		} `json:"vfprules-k2s"`
	} `json:"smallsetup"`
}

var _ = Describe("contract", func() {
	It("matches the HNS proxy configuration the K2s CNI applies", func() {
		content, err := os.ReadFile(filepath.Join("..", "..", filepath.FromSlash(hnsProxyConfigPath)))
		Expect(err).ToNot(HaveOccurred())

		var config k2sConfig
		Expect(json.Unmarshal(content, &config)).To(Succeed())

		actual := config.SmallSetup.VfpRules.HnsProxyConfig

		Expect(actual.InboundProxyPort).To(Equal(inboundProxyPort))
		Expect(actual.OutboundProxyPort).To(Equal(outboundProxyPort))
		Expect(actual.InboundPortExceptions).To(Equal(inboundPortExceptions))
		Expect(actual.OutboundPortExceptions).To(Equal(outboundPortExceptions))
	})
})
