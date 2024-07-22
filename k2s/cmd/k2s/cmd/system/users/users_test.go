// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/common"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

func TestUsersPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "users cmd Unit Tests", Label("unit", "ci", "users"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("users pkg", func() {
	Describe("add cmd", func() {
		Describe("newUserNotFoundFailure", func() {
			It("returns cmd failure with warn level severity", func() {
				input := errors.New("oops")

				actual := newUserNotFoundFailure(input)

				Expect(actual.Severity).To(Equal(common.SeverityWarning))
				Expect(actual.Code).To(Equal("user-not-found"))
				Expect(actual.Message).To(Equal("oops"))
			})
		})

		Describe("confirmOverwrite", func() {
			When("overwriting is enforced", func() {
				It("returns true without confirmation being shown", func() {
					const force = true
					var showConfirmationFunc func(...string) (bool, error)

					actual := confirmOverwrite(force, showConfirmationFunc)

					Expect(actual).To(BeTrue())
				})
			})

			When("overwriting is not enforced", func() {
				When("showing confirmation returns an error", func() {
					It("returns false", func() {
						const force = false
						showConfirmationFunc := func(s ...string) (bool, error) { return false, errors.New("oops") }

						actual := confirmOverwrite(force, showConfirmationFunc)

						Expect(actual).To(BeFalse())
					})
				})

				When("confirmation returns false", func() {
					It("returns false", func() {
						const force = false
						showConfirmationFunc := func(s ...string) (bool, error) { return false, nil }

						actual := confirmOverwrite(force, showConfirmationFunc)

						Expect(actual).To(BeFalse())
					})
				})

				When("confirmation returns true", func() {
					It("returns true", func() {
						const force = false
						showConfirmationFunc := func(s ...string) (bool, error) { return true, nil }

						actual := confirmOverwrite(force, showConfirmationFunc)

						Expect(actual).To(BeTrue())
					})
				})
			})
		})
	})
})
