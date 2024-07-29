// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package nodes_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/config"
	"github.com/siemens-healthineers/k2s/internal/nodes"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type sshExecutorMock struct {
	mock.Mock
}

func (m *sshExecutorMock) SetConfig(sshKeyPath string, remoteUser string, remoteHost string) {
	m.Called(sshKeyPath, remoteUser, remoteHost)
}

func (m *sshExecutorMock) Exec(cmd string) error {
	args := m.Called(cmd)

	return args.Error(0)
}

func (m *sshExecutorMock) ScpToRemote(source string, target string) error {
	args := m.Called(source, target)

	return args.Error(0)
}

func (m *sshExecutorMock) ScpFromRemote(source string, target string) error {
	args := m.Called(source, target)

	return args.Error(0)
}

func TestNodesPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "nodes pkg Unit Tests", Label("unit", "ci", "nodes"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("nodes pkg", func() {
	Describe("NewControlPlane", func() {
		When("control-plane config is missing", func() {
			It("returns error", func() {
				cfg := &config.Config{}

				actual, err := nodes.NewControlPlane(nil, cfg, "")

				Expect(actual).To(BeNil())
				Expect(err).To(MatchError(ContainSubstring("could not find control-plane")))
			})
		})

		When("control-plane config is present", func() {
			It("sets SSH access correctly up", func() {
				const controlPlaneName = "my-control-plane"
				const ipAddress = "my-address"
				const sshDir = "my-ssh-dir"
				const expectedKeyPath = sshDir + "\\" + controlPlaneName + "\\id_rsa"

				cfg := &config.Config{
					Host: config.HostConfig{
						SshDir: sshDir,
					},
					Nodes: config.Nodes{
						config.NodeConfig{
							IsControlPlane: true,
							IpAddress:      ipAddress,
						},
					},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), expectedKeyPath, "remote", ipAddress)

				actual, err := nodes.NewControlPlane(sshMock, cfg, controlPlaneName)

				Expect(err).ToNot(HaveOccurred())
				Expect(actual.Name()).To(Equal(controlPlaneName))

				sshMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("Exec", func() {
		When("cmd exec returns error", func() {
			It("returns error", func() {
				const cmd = "cmd"
				execErr := errors.New("oops")
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), cmd).Return(execErr)

				sut, err := nodes.NewControlPlane(sshMock, cfg, "")
				Expect(err).ToNot(HaveOccurred())

				actual := sut.Exec(cmd)

				Expect(actual).To(MatchError(execErr))
			})
		})

		When("cmd exec succeeds", func() {
			It("succeeds", func() {
				const cmd = "cmd"
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.Exec), cmd).Return(nil).Once()

				sut, err := nodes.NewControlPlane(sshMock, cfg, "controlPlaneName")
				Expect(err).ToNot(HaveOccurred())

				err = sut.Exec(cmd)

				Expect(err).ToNot(HaveOccurred())

				sshMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("CopyTo", func() {
		When("copy returns error", func() {
			It("returns error", func() {
				const source = "source"
				const target = "target"
				copyErr := errors.New("oops")
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.ScpToRemote), source, target).Return(copyErr)

				sut, err := nodes.NewControlPlane(sshMock, cfg, "")
				Expect(err).ToNot(HaveOccurred())

				actual := sut.CopyTo(source, target)

				Expect(actual).To(MatchError(copyErr))
			})
		})

		When("copy succeeds", func() {
			It("succeeds", func() {
				const source = "source"
				const target = "target"
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.ScpToRemote), source, target).Return(nil).Once()

				sut, err := nodes.NewControlPlane(sshMock, cfg, "")
				Expect(err).ToNot(HaveOccurred())

				err = sut.CopyTo(source, target)

				Expect(err).ToNot(HaveOccurred())

				sshMock.AssertExpectations(GinkgoT())
			})
		})
	})

	Describe("CopyFrom", func() {
		When("copy returns error", func() {
			It("returns error", func() {
				const source = "source"
				const target = "target"
				copyErr := errors.New("oops")
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.ScpFromRemote), source, target).Return(copyErr)

				sut, err := nodes.NewControlPlane(sshMock, cfg, "")
				Expect(err).ToNot(HaveOccurred())

				actual := sut.CopyFrom(source, target)

				Expect(actual).To(MatchError(copyErr))
			})
		})

		When("copy succeeds", func() {
			It("succeeds", func() {
				const source = "source"
				const target = "target"
				cfg := &config.Config{
					Host:  config.HostConfig{},
					Nodes: config.Nodes{config.NodeConfig{IsControlPlane: true}},
				}

				sshMock := &sshExecutorMock{}
				sshMock.On(reflection.GetFunctionName(sshMock.SetConfig), mock.Anything, mock.Anything, mock.Anything)
				sshMock.On(reflection.GetFunctionName(sshMock.ScpFromRemote), source, target).Return(nil).Once()

				sut, err := nodes.NewControlPlane(sshMock, cfg, "")
				Expect(err).ToNot(HaveOccurred())

				err = sut.CopyFrom(source, target)

				Expect(err).ToNot(HaveOccurred())

				sshMock.AssertExpectations(GinkgoT())
			})
		})
	})
})
