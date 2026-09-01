// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package api_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/api"
	"github.com/siemens-healthineers/k2s/internal/definitions"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type mockRestClient struct {
	mock.Mock
}

func (m *mockRestClient) SetTLSConfig(caCert, userCert, userKey []byte) error {
	return m.Called(caCert, userCert, userKey).Error(0)
}

func (m *mockRestClient) Post(url string, payload any, result any) error {
	return m.Called(url, payload, result).Error(0)
}

func TestApiPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "api pkg Unit Tests", Label("unit", "ci", "api"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ApiAccessVerifier", func() {
	var (
		verifier   *api.ApiAccessVerifier
		mockClient *mockRestClient
		userName   string
		server     string
		caCert     []byte
		userCert   []byte
		userKey    []byte
	)

	BeforeEach(func() {
		mockClient = &mockRestClient{}
		verifier = api.NewApiAccessVerifier(mockClient)
		userName = "testuser"
		server = "https://k8s-api.example.com"
		caCert = []byte("ca-cert")
		userCert = []byte("user-cert")
		userKey = []byte("user-key")
	})

	Describe("VerifyAccess", func() {
		When("TLS configuration fails", func() {
			It("returns an error", func() {
				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(errors.New("tls-config-error"))

				err := verifier.VerifyAccess(userName, server, caCert, userCert, userKey)

				Expect(err).To(MatchError(ContainSubstring("failed to set http client TLS config")))
			})
		})

		When("REST client POST fails", func() {
			It("returns an error", func() {
				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil)
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(errors.New("network-error"))

				err := verifier.VerifyAccess(userName, server, caCert, userCert, userKey)

				Expect(err).To(MatchError(ContainSubstring("failed to POST who-am-I request to K8s API")))
			})
		})

		When("user is not in required group", func() {
			It("returns an error", func() {
				response := api.SelfSubjectReview{
					Status: api.AuthStatus{
						UserInfo: api.UserInfo{
							Name:   userName,
							Groups: []string{"other-group", "another-group"},
						},
					},
				}

				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil)
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil).Run(func(args mock.Arguments) {
					arg := args.Get(2).(*api.SelfSubjectReview)
					*arg = response
				})

				err := verifier.VerifyAccess(userName, server, caCert, userCert, userKey)

				Expect(err).To(HaveOccurred())
				Expect(err).To(MatchError(ContainSubstring("not part of the group")))
			})
		})

		Context("when confirmed username does not match", func() {
			It("returns an error", func() {
				response := api.SelfSubjectReview{
					Status: api.AuthStatus{
						UserInfo: api.UserInfo{
							Name:   "different-user",
							Groups: []string{definitions.K2sUserGroup},
						},
					},
				}

				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil)
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil).Run(func(args mock.Arguments) {
					arg := args.Get(2).(*api.SelfSubjectReview)
					*arg = response
				})

				err := verifier.VerifyAccess(userName, server, caCert, userCert, userKey)

				Expect(err).To(HaveOccurred())
				Expect(err).To(MatchError(ContainSubstring("confirmed user name")))
				Expect(err).To(MatchError(ContainSubstring("does not match given user name")))
			})
		})

		Context("when verification succeeds", func() {
			It("returns no error for valid user in correct group", func() {
				response := api.SelfSubjectReview{
					Status: api.AuthStatus{
						UserInfo: api.UserInfo{
							Name:   userName,
							Groups: []string{definitions.K2sUserGroup, "some-other-group"},
						},
					},
				}

				mockClient.On(reflection.GetFunctionName(mockClient.SetTLSConfig), caCert, userCert, userKey).Return(nil)
				mockClient.On(reflection.GetFunctionName(mockClient.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil).Run(func(args mock.Arguments) {
					arg := args.Get(2).(*api.SelfSubjectReview)
					*arg = response
				})

				err := verifier.VerifyAccess(userName, server, caCert, userCert, userKey)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})
})
