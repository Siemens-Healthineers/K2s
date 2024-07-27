// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package factory_test

import (
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/config"
	factory "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/factory"
)

func TestClusterFactoryPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "status pkg Unit Tests", Label("unit", "ci", "status", "network", "factory"))
}

var _ = Describe("ClusterFactory", func() {
	var (
		cfg         *config.Config
		factoryInst *factory.ClusterFactory
		err         error
	)

	BeforeEach(func() {
		cfg = &config.Config{KubeConfig: "fake-kubeconfig", Namespace: "default"}
	})

	Describe("NewClusterFactory", func() {
		It("should create a new ClusterFactory", func() {
			factoryInst, err = factory.NewClusterFactory(cfg)
			Expect(err).To(HaveOccurred())
			Expect(factoryInst).To(BeNil())
		})
	})
})
