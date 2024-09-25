// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package cluster_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/cluster"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type restClientMock struct {
	mock.Mock
}

func (m *restClientMock) SetTlsClientConfig(caCert []byte, userCert []byte, userKey []byte) error {
	args := m.Called(caCert, userCert, userKey)

	return args.Error(0)
}

func (m *restClientMock) Post(url string, payload any, result any) error {
	args := m.Called(url, payload, result)

	return args.Error(0)
}

func TestClusterPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "cluster pkg Tests", Label("ci", "unit", "internal", "core", "users", "k8s", "cluster"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("cluster pkg", func() {
	Describe("clusterAccess", func() {
		Describe("VerifyAccess", func() {
			When("cluster CA cert cannot be decoded", func() {
				It("returns error", func() {
					clusterConfig := &cluster.ClusterParam{Cert: "invalid"}

					sut := cluster.NewClusterAccess(nil)

					err := sut.VerifyAccess(nil, clusterConfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode cluster cert")))
				})
			})

			When("user cert cannot be decoded", func() {
				It("returns error", func() {
					userConfig := &cluster.UserParam{Cert: "invalid"}
					clusterConfig := &cluster.ClusterParam{}

					sut := cluster.NewClusterAccess(nil)

					err := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode user cert")))
				})
			})

			When("user key cannot be decoded", func() {
				It("returns error", func() {
					userConfig := &cluster.UserParam{Key: "invalid"}
					clusterConfig := &cluster.ClusterParam{}

					sut := cluster.NewClusterAccess(nil)

					err := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode user key")))
				})
			})

			When("TLS client config could not be set", func() {
				It("returns error", func() {
					err := errors.New("oops")
					userConfig := &cluster.UserParam{}
					clusterConfig := &cluster.ClusterParam{}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(err)

					sut := cluster.NewClusterAccess(restMock)

					actualErr := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(actualErr).To(MatchError(SatisfyAll(
						ContainSubstring("could not set TLS client config"),
						ContainSubstring("oops"),
					)))
				})
			})

			When("who-am-I-request failed", func() {
				It("returns error", func() {
					err := errors.New("oops")
					userConfig := &cluster.UserParam{}
					clusterConfig := &cluster.ClusterParam{}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Return(err)

					sut := cluster.NewClusterAccess(restMock)

					actualErr := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(actualErr).To(MatchError(SatisfyAll(
						ContainSubstring("could not post who-am-I request"),
						ContainSubstring("oops"),
					)))
				})
			})

			When("user group validation failed", func() {
				It("returns error", func() {
					userConfig := &cluster.UserParam{
						Name:  "john",
						Group: "my-group",
					}
					clusterConfig := &cluster.ClusterParam{}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil)

					sut := cluster.NewClusterAccess(restMock)

					err := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(err).To(MatchError(ContainSubstring("user 'john' not part of the group 'my-group'")))
				})
			})

			When("username validation failed", func() {
				It("returns error", func() {
					const group = "my-group"
					const returnedUsername = "jessi"
					userConfig := &cluster.UserParam{
						Name:  "john",
						Group: group,
					}
					clusterConfig := &cluster.ClusterParam{}
					whoAmIResponse := &cluster.SelfSubjectReview{
						Status: cluster.AuthStatus{
							UserInfo: cluster.UserInfo{
								Name:   returnedUsername,
								Groups: []string{group},
							},
						},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Run(func(args mock.Arguments) {
						responseArg := args.Get(2).(*cluster.SelfSubjectReview)
						*responseArg = *whoAmIResponse
					}).Return(nil)

					sut := cluster.NewClusterAccess(restMock)

					err := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(err).To(MatchError(ContainSubstring("user name 'jessi' does not match given user name 'john'")))
				})
			})

			When("all succeeded", func() {
				It("returns nil", func() {
					const username = "john"
					const group = "my-group"
					userConfig := &cluster.UserParam{
						Name:  username,
						Group: group,
					}
					clusterConfig := &cluster.ClusterParam{}
					whoAmIResponse := &cluster.SelfSubjectReview{
						Status: cluster.AuthStatus{
							UserInfo: cluster.UserInfo{
								Name:   username,
								Groups: []string{group},
							},
						},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Run(func(args mock.Arguments) {
						responseArg := args.Get(2).(*cluster.SelfSubjectReview)
						*responseArg = *whoAmIResponse
					}).Return(nil)

					sut := cluster.NewClusterAccess(restMock)

					err := sut.VerifyAccess(userConfig, clusterConfig)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})
	})
})
