// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8sversion_test

import (
	"testing"

	u "github.com/siemens-healthineers/k2s/internal/primitives/strings"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/common"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/k8sversion"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

type testTerminalPrinter struct {
	log []string
}

func (t *testTerminalPrinter) Println(m ...any) {
	t.log = append(t.log, u.ToString(m[0]))
}

func (t *testTerminalPrinter) PrintCyanFg(text string) string {
	return text
}

func TestK8sversion(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8sversion Unit Tests", Label("unit", "ci"))
}

var _ = Describe("k8sversion", func() {
	Describe("PrintK8sVersionInfo", func() {
		Context("version info is unavailable", func() {
			It("returns error", func() {
				sut := k8sversion.NewK8sVersionPrinter(nil)

				err := sut.PrintK8sVersionInfo(nil)

				Expect(err).To(MatchError(MatchRegexp("no.+info retrieved")))
			})
		})

		Context("version info is available", func() {
			It("prints version info and returns nil", func() {
				versionInfo := &common.K8sVersionInfo{K8sServerVersion: "s-v1", K8sClientVersion: "c-v1"}
				printer := &testTerminalPrinter{
					log: []string{},
				}
				sut := k8sversion.NewK8sVersionPrinter(printer)

				err := sut.PrintK8sVersionInfo(versionInfo)

				Expect(err).ToNot(HaveOccurred())
				Expect(printer.log).To(HaveLen(2))
				Expect(printer.log[0]).To(ContainSubstring("server"))
				Expect(printer.log[0]).To(ContainSubstring(versionInfo.K8sServerVersion))
				Expect(printer.log[1]).To(ContainSubstring("client"))
				Expect(printer.log[1]).To(ContainSubstring(versionInfo.K8sClientVersion))
			})
		})
	})
})
