// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8s_test

import (
	"errors"
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/k8s"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
	"gopkg.in/yaml.v2"
)

type cmdExecutorMock struct {
	mock.Mock
}

type restClientMock struct {
	mock.Mock
}

func (m *cmdExecutorMock) ExecuteCmd(name string, arg ...string) error {
	args := m.Called(name, arg)

	return args.Error(0)
}

func (m *restClientMock) SetTlsClientConfig(caCert []byte, userCert []byte, userKey []byte) error {
	args := m.Called(caCert, userCert, userKey)

	return args.Error(0)
}

func (m *restClientMock) Post(url string, payload any, result any) error {
	args := m.Called(url, payload, result)

	return args.Error(0)
}

func TestK8sPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8s pkg Tests", Label("ci", "internal", "k8s"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("k8s pkg", func() {
	Describe("KubeconfigFile", func() {
		Describe("Path", Label("unit"), func() {
			It("returns path", func() {
				const path = "path"

				sut := k8s.NewKubeconfigFile(path, nil, nil)

				Expect(sut.Path()).To(Equal(path))
			})
		})

		Describe("SetCluster", Label("unit"), func() {
			When("kubectl set-cluster failed", func() {
				It("returns error", func() {
					const path = "path"
					execErr := errors.New("oops")
					clusterConfig := &k8s.ClusterConf{}

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
						return args[1] == "set-cluster"
					})).Return(execErr)

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.SetCluster(clusterConfig)

					Expect(err).To(MatchError(execErr))
				})
			})

			When("kubectl set failed", func() {
				It("returns error", func() {
					const path = "path"
					execErr := errors.New("oops")
					clusterConfig := &k8s.ClusterConf{}

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
						return args[1] == "set-cluster"
					})).Return(nil)
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
						return args[1] == "set"
					})).Return(execErr)

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.SetCluster(clusterConfig)

					Expect(err).To(MatchError(execErr))
				})
			})

			When("successful", func() {
				It("calls kubectl correctly", func() {
					const path = "path"
					const cmdName = "kubectl"
					const configParam = "config"
					clusterConfig := &k8s.ClusterConf{
						Name: "my-cluster",
						Cluster: k8s.Cluster{
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
							args[4] == clusterConfig.Cluster.Server &&
							args[5] == "--kubeconfig" &&
							args[6] == path

					})).Return(nil)
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), cmdName, mock.MatchedBy(func(args []string) bool {
						return args[0] == configParam &&
							args[1] == "set" &&
							args[2] == "clusters.my-cluster.certificate-authority-data" &&
							args[3] == clusterConfig.Cluster.Cert &&
							args[4] == "--kubeconfig" &&
							args[5] == path
					})).Return(nil)

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.SetCluster(clusterConfig)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("SetCredentials", Label("unit"), func() {
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

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

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

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.SetCredentials(username, certPath, keyPath)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("SetContext", Label("unit"), func() {
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

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

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

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.SetContext(context, username, clusterName)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("UseContext", Label("unit"), func() {
			When("kubectl exec failed", func() {
				It("returns error", func() {
					const path = "path"
					const context = "context"
					execErr := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(args []string) bool {
						return args[1] == "use-context"
					})).Return(execErr)

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

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

					sut := k8s.NewKubeconfigFile(path, execMock, nil)

					err := sut.UseContext(context)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("ReadFile", Label("integration"), func() {
			When("file read failed", func() {
				It("returns error", func() {
					sut := k8s.NewKubeconfigFile("non-existent", nil, nil)

					actual, err := sut.ReadFile()

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(os.ErrNotExist))
				})
			})

			When("file read successful", func() {
				var path string
				var writtenConfig *k8s.KubeconfigRoot

				BeforeEach(func() {
					path = filepath.Join(GinkgoT().TempDir(), "test.yaml")

					writtenConfig = &k8s.KubeconfigRoot{
						CurrentContext: "my-context",
					}

					bytes, err := yaml.Marshal(writtenConfig)
					Expect(err).ToNot(HaveOccurred())

					Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
				})

				It("reads kubeconfig file correctly", func() {
					sut := k8s.NewKubeconfigFile(path, nil, nil)

					actual, err := sut.ReadFile()

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.CurrentContext).To(Equal(writtenConfig.CurrentContext))
				})
			})
		})

		Describe("TestClusterAccess", Label("unit"), func() {
			When("user is not found", func() {
				It("returns error", func() {
					const username = "non-existent"
					const clusterName = "my-cluster"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{}

					sut := k8s.NewKubeconfigFile("", nil, nil)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found")))
				})
			})

			When("cluster is not found", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users: []k8s.UserConf{{Name: username}},
					}

					sut := k8s.NewKubeconfigFile("", nil, nil)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found")))
				})
			})

			When("cluster CA cert cannot be decoded", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users: []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{
							{
								Name: clusterName,
								Cluster: k8s.Cluster{
									Cert: "invalid",
								},
							},
						},
					}

					sut := k8s.NewKubeconfigFile("", nil, nil)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode cluster cert")))
				})
			})

			When("user cert cannot be decoded", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users: []k8s.UserConf{
							{
								Name: username,
								User: k8s.UserDetail{
									Cert: "invalid",
								},
							}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}

					sut := k8s.NewKubeconfigFile("", nil, nil)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode user cert")))
				})
			})

			When("user key cannot be decoded", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users: []k8s.UserConf{
							{
								Name: username,
								User: k8s.UserDetail{
									Key: "invalid",
								},
							}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}

					sut := k8s.NewKubeconfigFile("", nil, nil)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("could not decode user key")))
				})
			})

			When("TLS client config could not be set", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					err := errors.New("oops")
					kubeconfig := &k8s.KubeconfigRoot{
						Users:    []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(err)

					sut := k8s.NewKubeconfigFile("", nil, restMock)

					actualErr := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(actualErr).To(MatchError(SatisfyAll(
						ContainSubstring("could not set TLS client config"),
						ContainSubstring("oops"),
					)))
				})
			})

			When("who-am-I-request failed", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					err := errors.New("oops")
					kubeconfig := &k8s.KubeconfigRoot{
						Users:    []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Return(err)

					sut := k8s.NewKubeconfigFile("", nil, restMock)

					actualErr := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(actualErr).To(MatchError(SatisfyAll(
						ContainSubstring("could not post who-am-I request"),
						ContainSubstring("oops"),
					)))
				})
			})

			When("user group validation failed", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users:    []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewKubeconfigFile("", nil, restMock)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("user 'john' not part of the group 'my-group'")))
				})
			})

			When("username validation failed", func() {
				It("returns error", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					const returnedUsername = "jessi"
					kubeconfig := &k8s.KubeconfigRoot{
						Users:    []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}
					whoAmIResponse := &k8s.SelfSubjectReview{
						Status: k8s.AuthStatus{
							UserInfo: k8s.UserInfo{
								Name:   returnedUsername,
								Groups: []string{group},
							},
						},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Run(func(args mock.Arguments) {
						responseArg := args.Get(2).(*k8s.SelfSubjectReview)
						*responseArg = *whoAmIResponse
					}).Return(nil)

					sut := k8s.NewKubeconfigFile("", nil, restMock)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).To(MatchError(ContainSubstring("user name 'jessi' does not match given user name 'john'")))
				})
			})

			When("all succeeded", func() {
				It("returns nil", func() {
					const username = "john"
					const clusterName = "non-existent"
					const group = "my-group"
					kubeconfig := &k8s.KubeconfigRoot{
						Users:    []k8s.UserConf{{Name: username}},
						Clusters: []k8s.ClusterConf{{Name: clusterName}},
					}
					whoAmIResponse := &k8s.SelfSubjectReview{
						Status: k8s.AuthStatus{
							UserInfo: k8s.UserInfo{
								Name:   username,
								Groups: []string{group},
							},
						},
					}

					restMock := &restClientMock{}
					restMock.On(reflection.GetFunctionName(restMock.SetTlsClientConfig), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					restMock.On(reflection.GetFunctionName(restMock.Post), mock.Anything, mock.Anything, mock.Anything).Run(func(args mock.Arguments) {
						responseArg := args.Get(2).(*k8s.SelfSubjectReview)
						*responseArg = *whoAmIResponse
					}).Return(nil)

					sut := k8s.NewKubeconfigFile("", nil, restMock)

					err := sut.TestClusterAccess(username, clusterName, group, kubeconfig)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})
	})

	Describe("Clusters", func() {
		Describe("Find", func() {
			When("not found", func() {
				It("returns error", func() {
					const name = "non-existent"
					sut := k8s.Clusters{}

					actual, err := sut.Find(name)

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found")))
				})
			})

			When("found", func() {
				It("returns finding", func() {
					const name = "existent"
					sut := k8s.Clusters{
						k8s.ClusterConf{Name: name},
					}

					actual, err := sut.Find(name)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.Name).To(Equal(name))
				})
			})
		})
	})

	Describe("Users", func() {
		Describe("Find", func() {
			When("not found", func() {
				It("returns error", func() {
					const name = "non-existent"
					sut := k8s.Users{}

					actual, err := sut.Find(name)

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found")))
				})
			})

			When("found", func() {
				It("returns finding", func() {
					const name = "existent"
					sut := k8s.Users{
						k8s.UserConf{Name: name},
					}

					actual, err := sut.Find(name)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.Name).To(Equal(name))
				})
			})
		})
	})
})
