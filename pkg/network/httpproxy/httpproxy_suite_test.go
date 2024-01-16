// SPDX-FileCopyrightText: © 2023 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package main_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestHttpproxyUnitTests(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "httpproxy Unit Tests", Label("unit"))
}
