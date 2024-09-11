// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package users_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type createUserNameMock struct {
	mock.Mock
}

type sshAccessMock struct {
	mock.Mock
}

type k8sAccessMock struct {
	mock.Mock
}

type userMock struct {
	mock.Mock
}

func (m *createUserNameMock) createK2sUserName(winUserName string) string {
	args := m.Called(winUserName)

	return args.String(0)
}

func (m *sshAccessMock) GrantAccess(winUser users.WinUser, k2sUserName string) error {
	args := m.Called(winUser, k2sUserName)

	return args.Error(0)
}

func (m *k8sAccessMock) GrantAccess(winUser users.WinUser, k2sUserName string) error {
	args := m.Called(winUser, k2sUserName)

	return args.Error(0)
}

func (m *userMock) UserId() string {
	args := m.Called()

	return args.String(0)
}

func (m *userMock) Username() string {
	args := m.Called()

	return args.String(0)
}

func (m *userMock) HomeDir() string {
	args := m.Called()

	return args.String(0)
}

func TestUsersPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "users pkg Tests", Label("ci", "internal", "core", "users"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("users pkg", func() {
	Describe("winUserAdder", Label("unit"), func() {
		Describe("Add", func() {
			When("granting SSH access failes", func() {
				It("returns error", func() {
					sshError := errors.New("ssh-error")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					sshMock := &sshAccessMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.GrantAccess), mock.Anything, mock.Anything).Return(sshError)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccess), mock.Anything, mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.UserId)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Username)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := users.NewWinUserAdder(sshMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock)

					Expect(err).To(MatchError(sshError))
				})
			})

			When("granting K8s access failes", func() {
				It("returns error", func() {
					k8sError := errors.New("k8s-error")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					sshMock := &sshAccessMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.GrantAccess), mock.Anything, mock.Anything).Return(nil)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccess), mock.Anything, mock.Anything).Return(k8sError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.UserId)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Username)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := users.NewWinUserAdder(sshMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock)

					Expect(err).To(MatchError(k8sError))
				})
			})

			When("granting access failes completely", func() {
				It("returns all errors", func() {
					sshError := errors.New("ssh-error")
					k8sError := errors.New("k8s-error")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					sshMock := &sshAccessMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.GrantAccess), mock.Anything, mock.Anything).Return(sshError)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccess), mock.Anything, mock.Anything).Return(k8sError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.UserId)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Username)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := users.NewWinUserAdder(sshMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock)

					Expect(err).To(SatisfyAll(
						MatchError(sshError),
						MatchError(k8sError),
					))
				})
			})

			When("granting access succeeds", func() {
				It("returns nil", func() {
					const userName = "test-name"
					const k2sUserName = "k2s-test-name"

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.UserId)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Username)).Return(userName)
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), userName).Return(k2sUserName)

					sshMock := &sshAccessMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.GrantAccess), userMock, k2sUserName).Return(nil)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccess), userMock, k2sUserName).Return(nil)

					sut := users.NewWinUserAdder(sshMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock)

					Expect(err).ToNot(HaveOccurred())

					sshMock.AssertExpectations(GinkgoT())
					k8sMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
