// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
)

func TestSshPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ssh pkg Unit Tests", Label("unit", "ci", "ssh"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ssh pkg", func() {
	Describe("SshKeyPath", func() {
		It("constructs SSH key path correctly", func() {
			actual := ssh.SshKeyPath("my-dir")

			Expect(actual).To(Equal("my-dir\\kubemaster\\id_rsa"))
		})
	})
})
