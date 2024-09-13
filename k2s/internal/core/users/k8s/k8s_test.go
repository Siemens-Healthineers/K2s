// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8s_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestK8sPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8s pkg Tests", Label("ci", "unit", "internal", "core", "users", "k8s"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("k8s pkg", func() {
	Describe("k8sAccess", func() {
		Describe("GrantAccessTo", func() {
			It("needs to be implemented", func() {
				Skip("todo") // TODO: implement
			})
		})
	})
})
