// SPDX-FileCopyrightText: © 2024 Siemens Healthcare GmbH
//
// SPDX-License-Identifier: MIT

package workloaddeployer_test

import (
	"errors"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/clusterclient"
	cmdexecutor "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/cmdexecutor"
	workloaddeployer "github.com/siemens-healthineers/k2s/cmd/k2s/cmd/status/network/workloaddeployer"
	"github.com/siemens-healthineers/k2s/cmd/k2s/utils"
	"github.com/stretchr/testify/mock"
	"k8s.io/client-go/kubernetes/fake"
	"k8s.io/client-go/rest"
)

type MockCmdExecutor struct {
	mock.Mock
}

func (m *MockCmdExecutor) ExecCmd(args ...string) *cmdexecutor.CmdExecStatus {
	arguments := m.Called(args)
	return arguments.Get(0).(*cmdexecutor.CmdExecStatus)
}

func TestWorkLoadDeployerPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "workloaddeployer pkg Unit Tests", Label("unit", "ci", "status", "network", "workloaddeployer"))
}

var _ = Describe("WorkloadDeployer", func() {
	var (
		mockKubectl *MockCmdExecutor
		deployer    *workloaddeployer.WorkloadDeployer
		clientset   *fake.Clientset
		k8sClient   *clusterclient.K8sClientSet
		config      *rest.Config
	)

	BeforeEach(func() {
		mockKubectl = new(MockCmdExecutor)
		clientset = fake.NewSimpleClientset()
		config = &rest.Config{}
		k8sClient = &clusterclient.K8sClientSet{
			Clientset: clientset,
			Config:    config,
		}
		deployer = workloaddeployer.NewWorkloadDeployer(mockKubectl, *k8sClient)
	})

	Describe("Deploy", func() {
		It("should deploy successfully", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"kubemaster"},
			}

			mockKubectl.On("ExecCmd", []string{"apply", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\linux"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})
			mockKubectl.On("ExecCmd", []string{"rollout", "status", "deployment", "-n", "default"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})

			err := deployer.Deploy(param)
			Expect(err).NotTo(HaveOccurred())
		})

		It("should deploy only windows workload successfully", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"md2456cs2"},
			}

			mockKubectl.On("ExecCmd", []string{"apply", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\windows"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})
			mockKubectl.On("ExecCmd", []string{"rollout", "status", "deployment", "-n", "default"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})

			err := deployer.Deploy(param)
			Expect(err).NotTo(HaveOccurred())
		})

		It("should deploy all workloads successfully", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{},
			}

			mockKubectl.On("ExecCmd", []string{"apply", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})
			mockKubectl.On("ExecCmd", []string{"rollout", "status", "deployment", "-n", "default"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})

			err := deployer.Deploy(param)
			Expect(err).NotTo(HaveOccurred())
		})

		It("should return error if apply command fails", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"kubemaster"},
			}

			mockKubectl.On("ExecCmd", []string{"apply", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\linux"}).Return(&cmdexecutor.CmdExecStatus{Err: errors.New("apply error")})

			err := deployer.Deploy(param)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(Equal("apply error"))
		})

		It("should return error if rollout status command fails", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"kubemaster"},
			}

			mockKubectl.On("ExecCmd", []string{"apply", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\linux"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})
			mockKubectl.On("ExecCmd", []string{"rollout", "status", "deployment", "-n", "default"}).Return(&cmdexecutor.CmdExecStatus{Err: errors.New("rollout error")})

			err := deployer.Deploy(param)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(Equal("rollout error"))
		})
	})

	Describe("Remove", func() {
		It("should remove deployment successfully", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"kubemaster"},
			}

			mockKubectl.On("ExecCmd", []string{"delete", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\linux"}).Return(&cmdexecutor.CmdExecStatus{Err: nil})

			err := deployer.Remove(param)
			Expect(err).NotTo(HaveOccurred())
		})

		It("should return error if delete command fails", func() {
			param := workloaddeployer.DeployParam{
				Namespace: "default",
				NodeNames: []string{"kubemaster"},
			}

			mockKubectl.On("ExecCmd", []string{"delete", "-k", utils.InstallDir() + "\\k2s\\cmd\\k2s\\cmd\\status\\network\\workload\\linux"}).Return(&cmdexecutor.CmdExecStatus{Err: errors.New("delete error")})

			err := deployer.Remove(param)
			Expect(err).To(HaveOccurred())
			Expect(err.Error()).To(Equal("delete error"))
		})
	})
})
