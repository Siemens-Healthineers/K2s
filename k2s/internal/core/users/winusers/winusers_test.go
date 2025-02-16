// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package winusers_test

import (
	"log/slog"
	"os/user"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/winusers"
)

func TestWinusersPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "winusers pkg Tests", Label("ci", "internal", "winusers"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("winusers pkg", func() {
	Describe("FindByName", func() {
		When("is system account name", Label("unit"), func() {
			It("returns system account", func() {
				sut := winusers.NewWinUserProvider()

				result, err := sut.FindByName("SYSTEM")

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Name()).To(Equal("NT AUTHORITY\\SYSTEM"))
				Expect(result.Id()).To(Equal("S-1-5-18"))
			})
		})

		When("user not found", Label("integration"), func() {
			It("returns error", func() {
				sut := winusers.NewWinUserProvider()

				result, err := sut.FindByName("certainly-non-existent-user")

				Expect(result).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not find Windows user")))
			})
		})

		When("user found", Label("integration"), func() {
			It("returns user", func() {
				current, err := user.Current()
				Expect(err).ToNot(HaveOccurred())

				sut := winusers.NewWinUserProvider()

				result, err := sut.FindByName(current.Username)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Id()).To(Equal(current.Uid))
				Expect(result.Name()).To(Equal(current.Username))
				Expect(result.HomeDir()).To(Equal(current.HomeDir))
			})
		})
	})

	Describe("FindById", func() {
		When("is system account id", Label("unit"), func() {
			It("returns system account", func() {
				sut := winusers.NewWinUserProvider()

				result, err := sut.FindById("S-1-5-18")

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Name()).To(Equal("NT AUTHORITY\\SYSTEM"))
				Expect(result.Id()).To(Equal("S-1-5-18"))
			})
		})

		When("user not found", Label("integration"), func() {
			It("returns error", func() {
				sut := winusers.NewWinUserProvider()

				result, err := sut.FindById("certainly-non-existent-user")

				Expect(result).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not find Windows user")))
			})
		})

		When("user found", Label("integration"), func() {
			It("returns user", func() {
				current, err := user.Current()
				Expect(err).ToNot(HaveOccurred())

				sut := winusers.NewWinUserProvider()

				result, err := sut.FindById(current.Uid)

				Expect(err).ToNot(HaveOccurred())
				Expect(result.Id()).To(Equal(current.Uid))
				Expect(result.Name()).To(Equal(current.Username))
				Expect(result.HomeDir()).To(Equal(current.HomeDir))
			})
		})
	})

	Describe("Current", func() {
		It("returns current user", func() {
			current, err := user.Current()
			Expect(err).ToNot(HaveOccurred())

			sut := winusers.NewWinUserProvider()

			result, err := sut.Current()

			Expect(err).ToNot(HaveOccurred())
			Expect(result.Id()).To(Equal(current.Uid))
			Expect(result.Name()).To(Equal(current.Username))
			Expect(result.HomeDir()).To(Equal(current.HomeDir))
		})
	})
})
