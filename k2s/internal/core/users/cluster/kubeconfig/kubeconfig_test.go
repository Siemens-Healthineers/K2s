// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/contracts/config"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/definitions"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "kubeconfig pkg Unit Tests", Label("unit", "ci", "kubeconfig"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("KubeconfigResolver", func() {
	Describe("ResolveKubeconfigPath", func() {
		It("returns correct kubeconfig path", func() {
			config := config.NewKubeConfig("", "~/test-kube-dir", "")
			user := users.NewOSUser("", "", "c:\\users\\test-user")

			sut := kubeconfig.NewKubeconfigResolver(config)

			actual := sut.ResolveKubeconfigPath(user)

			Expect(actual).To(Equal("c:\\users\\test-user\\test-kube-dir\\" + definitions.KubeconfigName))
		})
	})
})
