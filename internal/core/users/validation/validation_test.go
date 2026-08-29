// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package validation_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/contracts/users"
	"github.com/siemens-healthineers/k2s/internal/core/users/validation"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type mockUserProvider struct {
	mock.Mock
}

func (m *mockUserProvider) CurrentUser() (*users.OSUser, error) {
	args := m.Called()

	return args.Get(0).(*users.OSUser), args.Error(1)
}

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "validation pkg Unit Tests", Label("unit", "ci", "validation"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("UserValidator", func() {
	Describe("DetermValidateUserineK2sUserName", func() {
		When("current user cannot be determined", func() {
			It("returns error", func() {
				var currentUser *users.OSUser
				targetUser := users.NewOSUser("", "", "")

				userProvider := &mockUserProvider{}
				userProvider.On(reflection.GetFunctionName(userProvider.CurrentUser)).Return(currentUser, errors.New("oops"))

				sut := validation.NewUserValidator(userProvider)

				err := sut.ValidateUser(targetUser)

				Expect(err).To(MatchError(ContainSubstring("failed to determine current user")))
			})
		})

		When("current user is the same as the target user", func() {
			It("returns error", func() {
				currentUser := users.NewOSUser("my-id", "my-name", "")
				targetUser := users.NewOSUser("my-id", "my-name", "")

				userProvider := &mockUserProvider{}
				userProvider.On(reflection.GetFunctionName(userProvider.CurrentUser)).Return(currentUser, nil)

				sut := validation.NewUserValidator(userProvider)

				err := sut.ValidateUser(targetUser)

				Expect(err).To(MatchError(ContainSubstring("cannot overwrite access of current user")))
			})
		})

		When("user is valid", func() {
			It("returns nil", func() {
				currentUser := users.NewOSUser("my-id", "my-name", "")
				targetUser := users.NewOSUser("different-id", "different-name", "")

				userProvider := &mockUserProvider{}
				userProvider.On(reflection.GetFunctionName(userProvider.CurrentUser)).Return(currentUser, nil)

				sut := validation.NewUserValidator(userProvider)

				err := sut.ValidateUser(targetUser)

				Expect(err).To(BeNil())
			})
		})
	})
})
