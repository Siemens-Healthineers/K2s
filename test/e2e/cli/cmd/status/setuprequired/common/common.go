// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT
package common

import (
	"k2sTest/framework/k2s"
	"strings"

	//lint:ignore ST1001 test framework code
	. "github.com/onsi/gomega"
)

const (
	VersionRegex = `v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)`
)

func ExpectAddonsGetPrinted(output string, addons []k2s.Addon) {
	Expect(output).To(SatisfyAll(
		ContainSubstring("Addons"),
		ContainSubstring("Enabled"),
		ContainSubstring("Disabled"),
	))

	lines := strings.Split(output, "\n")

	for _, addon := range addons {
		Expect(lines).To(ContainElement(SatisfyAll(
			ContainSubstring(addon.Metadata.Name),
			ContainSubstring(addon.Metadata.Description),
		)))
	}
}
