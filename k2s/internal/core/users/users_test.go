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
	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/core/users/common"
	"github.com/siemens-healthineers/k2s/internal/core/users/winusers"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type createUserNameMock struct {
	mock.Mock
}

type controlPlaneAccessMock struct {
	mock.Mock
}

type k8sAccessMock struct {
	mock.Mock
}

type userMock struct {
	mock.Mock
}

type userProviderMock struct {
	mock.Mock
}

func (m *createUserNameMock) createK2sUserName(winUserName string) string {
	args := m.Called(winUserName)

	return args.String(0)
}

func (m *controlPlaneAccessMock) GrantAccessTo(user common.User, currentUserName, k2sUserName string) (err error) {
	args := m.Called(user, currentUserName, k2sUserName)

	return args.Error(0)
}

func (m *k8sAccessMock) GrantAccessTo(user common.User, k2sUserName string) error {
	args := m.Called(user, k2sUserName)

	return args.Error(0)
}

func (m *userMock) Name() string {
	args := m.Called()

	return args.String(0)
}

func (m *userMock) HomeDir() string {
	args := m.Called()

	return args.String(0)
}

func (m *userProviderMock) FindByName(name string) (*winusers.User, error) {
	args := m.Called(name)

	return args.Get(0).(*winusers.User), args.Error(1)
}

func (m *userProviderMock) FindById(id string) (*winusers.User, error) {
	args := m.Called(id)

	return args.Get(0).(*winusers.User), args.Error(1)
}

func (m *userProviderMock) Current() (*winusers.User, error) {
	args := m.Called()

	return args.Get(0).(*winusers.User), args.Error(1)
}

func TestUsersPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "users pkg Unit Tests", Label("ci", "unit", "internal", "core", "users"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("users pkg", func() {
	Describe("winUserAdder", func() {
		Describe("Add", func() {
			When("granting control-plane access failes", func() {
				It("returns error", func() {
					const currentUser = "admin"
					cpError := errors.New("control-plane-error")

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					cpAccessMock := &controlPlaneAccessMock{}
					cpAccessMock.On(reflection.GetFunctionName(cpAccessMock.GrantAccessTo), userMock, currentUser, mock.Anything).Return(cpError)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccessTo), userMock, mock.Anything).Return(nil)

					sut := users.NewWinUserAdder(cpAccessMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock, currentUser)

					Expect(err).To(MatchError(cpError))
				})
			})

			When("granting K8s access failes", func() {
				It("returns error", func() {
					const currentUser = "admin"
					k8sError := errors.New("k8s-error")

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					cpAccessMock := &controlPlaneAccessMock{}
					cpAccessMock.On(reflection.GetFunctionName(cpAccessMock.GrantAccessTo), userMock, currentUser, mock.Anything).Return(nil)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccessTo), userMock, mock.Anything).Return(k8sError)

					sut := users.NewWinUserAdder(cpAccessMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock, currentUser)

					Expect(err).To(MatchError(k8sError))
				})
			})

			When("granting access failes completely", func() {
				It("returns all errors", func() {
					const currentUser = "admin"
					cpError := errors.New("control-plane-error")
					k8sError := errors.New("k8s-error")

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), mock.Anything).Return("")

					cpAccessMock := &controlPlaneAccessMock{}
					cpAccessMock.On(reflection.GetFunctionName(cpAccessMock.GrantAccessTo), userMock, currentUser, mock.Anything).Return(cpError)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccessTo), userMock, mock.Anything).Return(k8sError)

					sut := users.NewWinUserAdder(cpAccessMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock, currentUser)

					Expect(err).To(SatisfyAll(
						MatchError(cpError),
						MatchError(k8sError),
					))
				})
			})

			When("granting access succeeds", func() {
				It("returns nil", func() {
					const currentUser = "admin"
					const k2sUserName = "k2s-test-name"

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("test-name")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					userNameMock := &createUserNameMock{}
					userNameMock.On(reflection.GetFunctionName(userNameMock.createK2sUserName), userMock.Name()).Return(k2sUserName)

					cpAccessMock := &controlPlaneAccessMock{}
					cpAccessMock.On(reflection.GetFunctionName(cpAccessMock.GrantAccessTo), userMock, currentUser, k2sUserName).Return(nil)

					k8sMock := &k8sAccessMock{}
					k8sMock.On(reflection.GetFunctionName(k8sMock.GrantAccessTo), userMock, k2sUserName).Return(nil)

					sut := users.NewWinUserAdder(cpAccessMock, k8sMock, userNameMock.createK2sUserName)

					err := sut.Add(userMock, currentUser)

					Expect(err).ToNot(HaveOccurred())

					cpAccessMock.AssertExpectations(GinkgoT())
					k8sMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})

	Describe("CreateK2sUserName", func() {
		It("creates K2s user name correctly", func() {
			const input = "my domain\\my user"

			actual := users.CreateK2sUserName(input)

			Expect(actual).To(Equal("k2s-my-domain-my-user"))
		})
	})

	Describe("usersManagement", func() {
		Describe("NewUsersManagement", func() {
			When("control-plane config not found", func() {
				It("returns error", func() {
					cfg := &config.Config{Nodes: []config.NodeConfig{}}

					sut, err := users.NewUsersManagement(cfg, nil, nil)

					Expect(sut).To(BeNil())
					Expect(err).To(MatchError("could not find control-plane node config"))
				})
			})
		})

		Describe("AddUserByName", func() {
			When("Windows user not found", func() {
				It("returns user-not-found error", func() {
					const userName = "test-user"
					findError := errors.New("oops")
					cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

					userProviderMock := &userProviderMock{}
					userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindByName), userName).Return(&winusers.User{}, findError)

					sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

					Expect(err).ToNot(HaveOccurred())

					err = sut.AddUserByName(userName)

					Expect(err).To(MatchError(users.UserNotFoundErr("oops")))
				})
			})

			When("Windows user found", func() {
				When("determining current Windows user failes", func() {
					It("returns error", func() {
						const userName = "test-user"
						expectedError := errors.New("oops")
						cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

						userProviderMock := &userProviderMock{}
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindByName), userName).Return(&winusers.User{}, nil)
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.Current)).Return(&winusers.User{}, expectedError)

						sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

						Expect(err).ToNot(HaveOccurred())

						err = sut.AddUserByName(userName)

						Expect(err).To(MatchError(expectedError))
					})
				})

				When("user-to-grant-access-to is Windows user", func() {
					It("returns error", func() {
						user := winusers.NewUser("123", "test-user", "")
						cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

						userProviderMock := &userProviderMock{}
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindByName), user.Name()).Return(user, nil)
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.Current)).Return(user, nil)

						sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

						Expect(err).ToNot(HaveOccurred())

						err = sut.AddUserByName(user.Name())

						Expect(err).To(MatchError(SatisfyAll(
							ContainSubstring("cannot overwrite"),
							ContainSubstring("name='test-user'"),
							ContainSubstring("id='123'"),
						)))
					})
				})
			})
		})

		Describe("AddUserById", func() {
			When("Windows user not found", func() {
				It("returns user-not-found error", func() {
					const userId = "123"
					findError := errors.New("oops")
					cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

					userProviderMock := &userProviderMock{}
					userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindById), userId).Return(&winusers.User{}, findError)

					sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

					Expect(err).ToNot(HaveOccurred())

					err = sut.AddUserById(userId)

					Expect(err).To(MatchError(users.UserNotFoundErr("oops")))
				})
			})

			When("Windows user found", func() {
				When("determining current Windows user failes", func() {
					It("returns error", func() {
						const userId = "test-user"
						expectedError := errors.New("oops")
						cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

						userProviderMock := &userProviderMock{}
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindById), userId).Return(&winusers.User{}, nil)
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.Current)).Return(&winusers.User{}, expectedError)

						sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

						Expect(err).ToNot(HaveOccurred())

						err = sut.AddUserById(userId)

						Expect(err).To(MatchError(expectedError))
					})
				})

				When("user-to-grant-access-to is Windows user", func() {
					It("returns error", func() {
						user := winusers.NewUser("123", "test-user", "")
						cfg := &config.Config{Nodes: []config.NodeConfig{{IsControlPlane: true}}}

						userProviderMock := &userProviderMock{}
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.FindById), user.Id()).Return(user, nil)
						userProviderMock.On(reflection.GetFunctionName(userProviderMock.Current)).Return(user, nil)

						sut, err := users.NewUsersManagement(cfg, nil, userProviderMock)

						Expect(err).ToNot(HaveOccurred())

						err = sut.AddUserById(user.Id())

						Expect(err).To(MatchError(SatisfyAll(
							ContainSubstring("cannot overwrite"),
							ContainSubstring("name='test-user'"),
							ContainSubstring("id='123'"),
						)))
					})
				})
			})
		})
	})
})
