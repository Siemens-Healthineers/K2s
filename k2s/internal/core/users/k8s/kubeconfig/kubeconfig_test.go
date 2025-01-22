// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package kubeconfig_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/kubeconfig"
	bkc "github.com/siemens-healthineers/k2s/internal/k8s/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type cmdExecutorMock struct {
	mock.Mock
}

func (m *cmdExecutorMock) ExecuteCmd(name string, arg ...string) error {
	args := m.Called(name, arg)

	return args.Error(0)
}

func TestKubeconfigPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "kubeconfig pkg Tests", Label("unit", "ci", "internal", "core", "users", "k8s", "kubeconfig"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("kubeconfig pkg", func() {
	Describe("FilePath", func() {
		It("returns path", func() {
			const path = "path"

			sut := kubeconfig.NewKubeconfigWriter(path, nil)

			Expect(sut.FilePath()).To(Equal(path))
		})
	})

	Describe("SetCluster", func() {
		When("kubectl set-cluster failed", func() {
			It("returns error", func() {
				const path = "path"
				execErr := errors.New("oops")
				clusterConfig := &bkc.ClusterEntry{}

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "set-cluster"
				})).Return(execErr)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetCluster(clusterConfig)

				Expect(err).To(MatchError(execErr))
			})
		})

		When("kubectl set failed", func() {
			It("returns error", func() {
				const path = "path"
				execErr := errors.New("oops")
				clusterConfig := &bkc.ClusterEntry{}

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "set-cluster"
				})).Return(nil)
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "set"
				})).Return(execErr)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetCluster(clusterConfig)

				Expect(err).To(MatchError(execErr))
			})
		})

		When("successful", func() {
			It("calls kubectl correctly", func() {
				const path = "path"
				const cmdName = "kubectl"
				const configParam = "config"
				clusterConfig := &bkc.ClusterEntry{
					Name: "my-cluster",
					Details: bkc.ClusterDetails{
						Server: "my-server",
						Cert:   "my-cert",
					},
				}

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
					return args[0] == configParam &&
						args[1] == "set-cluster" &&
						args[2] == clusterConfig.Name &&
						args[3] == "--server" &&
						args[4] == clusterConfig.Details.Server &&
						args[5] == "--kubeconfig" &&
						args[6] == path

				})).Return(nil)
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
					return args[0] == configParam &&
						args[1] == "set" &&
						args[2] == "clusters.my-cluster.certificate-authority-data" &&
						args[3] == clusterConfig.Details.Cert &&
						args[4] == "--kubeconfig" &&
						args[5] == path
				})).Return(nil)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetCluster(clusterConfig)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("SetCredentials", func() {
		When("kubectl exec failed", func() {
			It("returns error", func() {
				const path = "path"
				const username = "username"
				const certPath = "cert-path"
				const keyPath = "key-path"
				execErr := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "set-credentials"
				})).Return(execErr)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetCredentials(username, certPath, keyPath)

				Expect(err).To(MatchError(execErr))
			})
		})

		When("successful", func() {
			It("calls kubectl correctly", func() {
				const path = "path"
				const cmdName = "kubectl"
				const configParam = "config"
				const username = "username"
				const certPath = "cert-path"
				const keyPath = "key-path"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
					return args[0] == configParam &&
						args[1] == "set-credentials" &&
						args[2] == username &&
						args[3] == "--client-certificate" &&
						args[4] == certPath &&
						args[5] == "--client-key" &&
						args[6] == keyPath &&
						args[7] == "--embed-certs=true" &&
						args[8] == "--kubeconfig" &&
						args[9] == path
				})).Return(nil)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetCredentials(username, certPath, keyPath)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("SetContext", func() {
		When("kubectl exec failed", func() {
			It("returns error", func() {
				const path = "path"
				const username = "username"
				const context = "context"
				const clusterName = "my-cluster"
				execErr := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "set-context"
				})).Return(execErr)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetContext(username, context, clusterName)

				Expect(err).To(MatchError(execErr))
			})
		})

		When("successful", func() {
			It("calls kubectl correctly", func() {
				const path = "path"
				const cmdName = "kubectl"
				const configParam = "config"
				const username = "john"
				const context = "context"
				const clusterName = "my-cluster"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
					return args[0] == configParam &&
						args[1] == "set-context" &&
						args[2] == context &&
						args[3] == "--cluster=my-cluster" &&
						args[4] == "--user=john" &&
						args[5] == "--kubeconfig" &&
						args[6] == path

				})).Return(nil)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.SetContext(context, username, clusterName)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("UseContext", func() {
		When("kubectl exec failed", func() {
			It("returns error", func() {
				const path = "path"
				const context = "context"
				execErr := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
					return args[1] == "use-context"
				})).Return(execErr)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.UseContext(context)

				Expect(err).To(MatchError(execErr))
			})
		})

		When("successful", func() {
			It("calls kubectl correctly", func() {
				const path = "path"
				const cmdName = "kubectl"
				const configParam = "config"
				const context = "context"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
					return args[0] == configParam &&
						args[1] == "use-context" &&
						args[2] == context &&
						args[3] == "--kubeconfig" &&
						args[4] == path

				})).Return(nil)

				sut := kubeconfig.NewKubeconfigWriter(path, execMock)

				err := sut.UseContext(context)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})
})
