// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package node_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestNodePkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node pkg Unit Tests", Label("unit", "ci", "node"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("node pkg", func() {
})
