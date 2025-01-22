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
	"github.com/siemens-healthineers/k2s/internal/k8s/kubeconfig"
	"gopkg.in/yaml.v3"
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
			var writtenConfig *kubeconfig.KubeconfigRoot

			BeforeEach(func() {
				path = filepath.Join(GinkgoT().TempDir(), "test.yaml")

				writtenConfig = &kubeconfig.KubeconfigRoot{
					CurrentContext: "my-context",
				}

				bytes, err := yaml.Marshal(writtenConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("reads kubeconfig file correctly", func() {
				actual, err := kubeconfig.ReadFile(path)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.CurrentContext).To(Equal(writtenConfig.CurrentContext))
			})
		})
	})

	Describe("KubeconfigRoot", Label("unit"), func() {
		Describe("FindCluster", func() {
			When("not found", func() {
				It("returns error", func() {
					const name = "non-existent"
					sut := kubeconfig.KubeconfigRoot{}

					actual, err := sut.FindCluster(name)

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("cluster 'non-existent' not found")))
				})
			})

			When("found", func() {
				It("returns finding", func() {
					const name = "existent"
					sut := kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{{Name: name}},
					}

					actual, err := sut.FindCluster(name)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.Name).To(Equal(name))
				})
			})
		})

		Describe("FindUser", func() {
			When("not found", func() {
				It("returns error", func() {
					const name = "non-existent"
					sut := kubeconfig.KubeconfigRoot{}

					actual, err := sut.FindUser(name)

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("user 'non-existent' not found")))
				})
			})

			When("found", func() {
				It("returns finding", func() {
					const name = "existent"
					sut := kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{{Name: name}},
					}

					actual, err := sut.FindUser(name)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.Name).To(Equal(name))
				})
			})
		})

		Describe("FindContextByCluster", func() {
			When("not found", func() {
				It("returns error", func() {
					const clusterName = "non-existent"
					sut := kubeconfig.KubeconfigRoot{}

					actual, err := sut.FindContextByCluster(clusterName)

					Expect(actual).To(BeNil())
					Expect(err).To(MatchError(ContainSubstring("context for cluster 'non-existent' not found")))
				})
			})

			When("found", func() {
				It("returns finding", func() {
					const clusterName = "existent"
					const contextName = "my-ctx"

					sut := kubeconfig.KubeconfigRoot{
						Contexts: []kubeconfig.ContextEntry{{
							Name: contextName,
							Details: kubeconfig.ContextDetails{
								Cluster: clusterName,
							},
						}},
					}

					actual, err := sut.FindContextByCluster(clusterName)

					Expect(err).ToNot(HaveOccurred())
					Expect(actual.Name).To(Equal(contextName))
				})
			})
		})
	})
})
