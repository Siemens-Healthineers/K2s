// SPDX-FileCopyrightText:  © 2026 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package naming_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/naming"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "naming pkg Unit Tests", Label("unit", "ci", "naming"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("DetermineK8sContext", func() {
	Describe("DetermineK8sContext", func() {
		It("determines K8s context name for K2s cluster", func() {
			actual := naming.DetermineK8sContext("test-user", "test-cluster")

			Expect(actual).To(Equal("test-user@test-cluster"))
		})
	})
})
