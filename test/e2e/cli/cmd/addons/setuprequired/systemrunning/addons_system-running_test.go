// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package systemrunning

import (
	"context"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"k2sTest/framework"
	"k2sTest/framework/k2s"
)

var suite *framework.K2sTestSuite
var addons []k2s.Addon

func TestLs(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "addons CLI Command Acceptance Tests for K2s being started", Label("cli", "acceptance", "setup-required", "addons", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning)
	addons = suite.AddonsInfo().AllAddons(suite.RootDir())
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("addons commands", func() {
	It("status", func() {
		Skip("test to be implemented")
	})
})
