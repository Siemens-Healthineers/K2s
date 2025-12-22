// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package dsl

import (
	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

func (k2s *K2s) VerifyAddonIsEnabled(name string, implementation ...string) {
	implementationName := ""
	if len(implementation) > 0 {
		implementationName = implementation[0]
	}

	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	addons := k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()

	Expect(addons).To(ContainElement(SatisfyAll(
		HaveField("Name", name),
		HaveField("Implementation", implementationName),
	)))
}

func (k2s *K2s) VerifyAddonIsDisabled(name string, implementation ...string) {
	implementationName := ""
	if len(implementation) > 0 {
		implementationName = implementation[0]
	}

	k2s.suite.SetupInfo().ReloadRuntimeConfig()

	addons := k2s.suite.SetupInfo().RuntimeConfig.ClusterConfig().EnabledAddons()

	Expect(addons).ToNot(ContainElement(SatisfyAll(
		HaveField("Name", name),
		HaveField("Implementation", implementationName),
	)))
}
