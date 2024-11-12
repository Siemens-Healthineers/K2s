// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package ssh

import (
	"context"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/test/framework"
)

var suite *framework.K2sTestSuite

func TestSsh(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system ssh CLI Commands Acceptance Tests", Label("cli", "system", "ssh", "m", "w", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system ssh", func() {

	Describe("m connect", func() {
		It("connects to Linux node", func(ctx context.Context) {
			Skip("test to be implemented")
		})
	})

	Describe("m command", func() {
		It("runs a command on Linux node", func(ctx context.Context) {
			output := suite.K2sCli().Run(ctx, "system", "ssh", "m", "--", "echo ssh-m-test")

			Expect(output).To(Equal("ssh-m-test\n"))
		})
	})

	Describe("w connect", func() {
		It("connects to Windows node", func(ctx context.Context) {
			Skip("test to be implemented")
		})
	})

	Describe("w command", func() {
		It("runs a command on Windows node", func(ctx context.Context) {
			Skip("test to be implemented")
		})
	})
})
