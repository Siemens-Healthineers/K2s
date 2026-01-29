// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package decoding_test

import (
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/core/users/cluster/decoding"
)

func TestPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "decoding pkg Unit Tests", Label("unit", "ci", "decoding"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("CredentialsDecoder", func() {
	Describe("DecodeK8sApiCredentials", func() {
		When("decoding cluster cert failes", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.ClusterConfig{
					Cert: "invalid-base64",
				}

				sut := decoding.NewCredentialsDecoder()

				caCert, userCert, userKey, err := sut.DecodeK8sApiCredentials(clusterConfig, nil)

				Expect(err).To(MatchError(ContainSubstring("failed to decode cluster certificate")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding user cert fails", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.ClusterConfig{
					Cert: "AFFE",
				}
				userConfig := &kubeconfig.UserConfig{
					Cert: "invalid-base64",
				}

				sut := decoding.NewCredentialsDecoder()

				caCert, userCert, userKey, err := sut.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).To(MatchError(ContainSubstring("failed to decode user certificate")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding user key fails", func() {
			It("returns error", func() {
				clusterConfig := &kubeconfig.ClusterConfig{
					Cert: "AFFE",
				}
				userConfig := &kubeconfig.UserConfig{
					Cert: "AFFE",
					Key:  "invalid-base64",
				}

				sut := decoding.NewCredentialsDecoder()

				caCert, userCert, userKey, err := sut.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).To(MatchError(ContainSubstring("failed to decode user key")))
				Expect(caCert).To(BeNil())
				Expect(userCert).To(BeNil())
				Expect(userKey).To(BeNil())
			})
		})

		When("decoding is successful", func() {
			It("returns decoded credentials", func() {
				clusterConfig := &kubeconfig.ClusterConfig{
					Cert: "dGVzdC1jYQ==",
				}
				userConfig := &kubeconfig.UserConfig{
					Cert: "dGVzdC1jZXJ0",
					Key:  "dGVzdC1rZXk=",
				}

				sut := decoding.NewCredentialsDecoder()

				caCert, userCert, userKey, err := sut.DecodeK8sApiCredentials(clusterConfig, userConfig)

				Expect(err).ToNot(HaveOccurred())
				Expect(caCert).To(Equal([]byte("test-ca")))
				Expect(userCert).To(Equal([]byte("test-cert")))
				Expect(userKey).To(Equal([]byte("test-key")))
			})
		})
	})
})
