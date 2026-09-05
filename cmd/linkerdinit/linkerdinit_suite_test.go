// SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
//
// SPDX-License-Identifier: MIT

package main

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestLinkerdInitUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "linkerdinit Unit Tests", Label("unit", "ci"))
}
