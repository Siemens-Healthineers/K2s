// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package kubeconfig_test

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	contracts "github.com/siemens-healthineers/k2s/internal/contracts/kubeconfig"
	"github.com/siemens-healthineers/k2s/internal/providers/kubeconfig"
	"gopkg.in/yaml.v2"
)

func TestKubeconfigPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "kubeconfig pkg Tests", Label("ci", "internal", "k8s", "kubeconfig"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("kubeconfig pkg", func() {
	Describe("ReadFile", Label("integration"), func() {
		When("file read failed", func() {
			It("returns error", func() {
				actual, err := kubeconfig.ReadFile("non-existent")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(os.ErrNotExist))
			})
		})

		When("file read successful", func() {
			var path string
			var writtenConfig map[string]any

			BeforeEach(func() {
				path = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				writtenConfig = map[string]any{
					"current-context": "my-context",
				}

				bytes, err := yaml.Marshal(writtenConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("reads kubeconfig file correctly", func() {
				actual, err := kubeconfig.ReadFile(path)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.CurrentContext).To(Equal(writtenConfig["current-context"]))
			})
		})
	})

	Describe("FindCluster", func() {
		When("not found", func() {
			It("returns error", func() {
				const name = "non-existent"
				config := &contracts.Kubeconfig{}

				actual, err := kubeconfig.FindCluster(config, name)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const name = "existent"
				config := &contracts.Kubeconfig{
					Clusters: []contracts.ClusterConfig{{Name: name}},
				}

				actual, err := kubeconfig.FindCluster(config, name)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(name))
			})
		})
	})

	Describe("FindUser", func() {
		When("not found", func() {
			It("returns error", func() {
				const name = "non-existent"
				config := &contracts.Kubeconfig{}

				actual, err := kubeconfig.FindUser(config, name)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const name = "existent"
				config := &contracts.Kubeconfig{
					Users: []contracts.UserConfig{{Name: name}},
				}

				actual, err := kubeconfig.FindUser(config, name)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(name))
			})
		})
	})

	Describe("FindContextByCluster", func() {
		When("not found", func() {
			It("returns error", func() {
				const clusterName = "non-existent"
				config := &contracts.Kubeconfig{}

				actual, err := kubeconfig.FindContextByCluster(config, clusterName)

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("context for cluster 'non-existent' not found")))
			})
		})

		When("found", func() {
			It("returns finding", func() {
				const clusterName = "existent"
				const contextName = "my-ctx"

				config := &contracts.Kubeconfig{
					Contexts: []contracts.ContextConfig{
						{
							Name:    contextName,
							Cluster: clusterName,
						},
					},
				}

				actual, err := kubeconfig.FindContextByCluster(config, clusterName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name).To(Equal(contextName))
			})
		})
	})

	Describe("FindK8sApiCredentials", func() {
		When("context not found", func() {
			It("returns error", func() {
				const contextName = "non-existent"
				config := &contracts.Kubeconfig{}

				cluster, user, err := kubeconfig.FindK8sApiCredentials(config, contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("context 'non-existent' not found")))
			})
		})

		When("user not found", func() {
			It("returns error", func() {
				const contextName = "my-context"
				config := &contracts.Kubeconfig{
					Contexts: []contracts.ContextConfig{
						{
							Name: contextName,
							User: "non-existent",
						},
					},
				}

				cluster, user, err := kubeconfig.FindK8sApiCredentials(config, contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found in kubeconfig")))
			})
		})

		When("cluster not found", func() {
			It("returns error", func() {
				const contextName = "my-context"
				const userName = "my-user"
				config := &contracts.Kubeconfig{
					Contexts: []contracts.ContextConfig{
						{
							Name:    contextName,
							User:    userName,
							Cluster: "non-existent",
						},
					},
					Users: []contracts.UserConfig{{Name: userName}},
				}

				cluster, user, err := kubeconfig.FindK8sApiCredentials(config, contextName)

				Expect(cluster).To(BeNil())
				Expect(user).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found in kubeconfig")))
			})
		})

		When("API credentials found", func() {
			It("returns API credentials", func() {
				const contextName = "my-context"
				const userName = "my-user"
				const clusterName = "my-cluster"
				config := &contracts.Kubeconfig{
					Contexts: []contracts.ContextConfig{
						{
							Name:    contextName,
							User:    userName,
							Cluster: clusterName,
						},
					},
					Users:    []contracts.UserConfig{{Name: userName}},
					Clusters: []contracts.ClusterConfig{{Name: clusterName}},
				}

				cluster, user, err := kubeconfig.FindK8sApiCredentials(config, contextName)

				Expect(err).ToNot(HaveOccurred())
				Expect(cluster.Name).To(Equal(clusterName))
				Expect(user.Name).To(Equal(userName))
			})
		})
	})
})
