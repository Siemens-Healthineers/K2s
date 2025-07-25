// SPDX-FileCopyrightText:  © 2025 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package k8s_test

import (
	"log/slog"
	"os"
	"path/filepath"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/k8s"
	"github.com/siemens-healthineers/k2s/internal/k8s/kubeconfig"
	"gopkg.in/yaml.v3"
)

func TestK8sPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8s pkg Tests", Label("integration", "ci", "internal", "k8s"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("k8s pkg", Ordered, func() {
	const k2sContextName = "my-ctx"

	Describe("ReadContext", func() {
		When("error while reading kubeconfig occurred", func() {
			It("returns error", func() {
				const dir = "non-existent"

				actual, err := k8s.ReadContext(dir, "")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not read kubeconfig")))
			})
		})

		When("K2s cluster cannot be found in kubeconfig", func() {
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				path := filepath.Join(dir, k8s.KubeconfigName)

				testConfig := &kubeconfig.KubeconfigRoot{}

				bytes, err := yaml.Marshal(testConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("returns error", func() {
				actual, err := k8s.ReadContext(dir, "")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not find K2s cluster config")))
			})
		})

		When("successful", func() {
			const clusterName = "my-cluster"
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				path := filepath.Join(dir, k8s.KubeconfigName)

				testConfig := &kubeconfig.KubeconfigRoot{
					Contexts: []kubeconfig.ContextEntry{
						{
							Name: k2sContextName,
							Details: kubeconfig.ContextDetails{
								Cluster: clusterName,
							},
						},
					},
					CurrentContext: k2sContextName,
				}

				bytes, err := yaml.Marshal(testConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("returns K8s context", func() {
				actual, err := k8s.ReadContext(dir, clusterName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual).ToNot(BeNil())
			})
		})
	})

	Describe("K8sContext", func() {
		Describe("IsK2sContext", func() {
			When("is K2s context", func() {
				const clusterName = "my-cluster"
				var dir string

				BeforeEach(func() {
					dir = GinkgoT().TempDir()
					path := filepath.Join(dir, k8s.KubeconfigName)

					testConfig := &kubeconfig.KubeconfigRoot{
						Contexts: []kubeconfig.ContextEntry{
							{
								Name: k2sContextName,
								Details: kubeconfig.ContextDetails{
									Cluster: clusterName,
								},
							},
						},
						CurrentContext: k2sContextName,
					}

					bytes, err := yaml.Marshal(testConfig)
					Expect(err).ToNot(HaveOccurred())

					Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
				})

				It("returns true", func() {
					sut, err := k8s.ReadContext(dir, clusterName)
					Expect(err).ToNot(HaveOccurred())

					actual := sut.IsK2sContext()

					Expect(actual).To(BeTrue())
				})
			})

			When("is not K2s context", func() {
				const clusterName = "my-cluster"
				var dir string

				BeforeEach(func() {
					dir = GinkgoT().TempDir()
					path := filepath.Join(dir, k8s.KubeconfigName)

					testConfig := &kubeconfig.KubeconfigRoot{
						Contexts: []kubeconfig.ContextEntry{
							{
								Name: k2sContextName,
								Details: kubeconfig.ContextDetails{
									Cluster: clusterName,
								},
							},
						},
						CurrentContext: "not-K2s-context",
					}

					bytes, err := yaml.Marshal(testConfig)
					Expect(err).ToNot(HaveOccurred())

					Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
				})

				It("returns true", func() {
					sut, err := k8s.ReadContext(dir, clusterName)
					Expect(err).ToNot(HaveOccurred())

					actual := sut.IsK2sContext()

					Expect(actual).To(BeFalse())
				})
			})
		})

		Describe("K2sContextName", func() {
			const clusterName = "my-cluster"
			var dir string

			BeforeEach(func() {
				dir = GinkgoT().TempDir()
				path := filepath.Join(dir, k8s.KubeconfigName)

				testConfig := &kubeconfig.KubeconfigRoot{
					Contexts: []kubeconfig.ContextEntry{
						{
							Name: k2sContextName,
							Details: kubeconfig.ContextDetails{
								Cluster: clusterName,
							},
						},
					},
					CurrentContext: "not-K2s-context",
				}

				bytes, err := yaml.Marshal(testConfig)
				Expect(err).ToNot(HaveOccurred())

				Expect(os.WriteFile(path, bytes, os.ModePerm)).To(Succeed())
			})

			It("returns correct K2s context", func() {
				sut, err := k8s.ReadContext(dir, clusterName)
				Expect(err).ToNot(HaveOccurred())

				actual := sut.K2sContextName()

				Expect(actual).To(Equal(k2sContextName))
			})
		})
	})
})
