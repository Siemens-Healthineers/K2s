// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package scp_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/nodes/scp"
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

func TestScpPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "scp pkg Tests", Label("ci", "unit", "internal", "core", "users", "nodes", "scp"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("scp pkg", func() {
	Describe("scp", func() {
		Describe("ScpToRemote", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const source = "source"
					const target = "target"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := scp.NewScp(execMock, "", "")

					actual := sut.CopyToRemote(source, target)

					Expect(actual).To(MatchError(SatisfyAll(
						ContainSubstring(source),
						ContainSubstring(target),
						ContainSubstring(err.Error()),
					)))
				})
			})

			When("cmd exec succeeds", func() {
				It("succeeds", func() {
					const keyPath = "path"
					const remote = "user@host"
					const source = "source"
					const target = "target"
					const expectedRemoteTarget = "user@host:target"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-3] == keyPath &&
							arg[len(arg)-2] == source &&
							arg[len(arg)-1] == expectedRemoteTarget
					})).Return(nil)

					sut := scp.NewScp(execMock, keyPath, remote)

					err := sut.CopyToRemote(source, target)

					Expect(err).ToNot(HaveOccurred())

					execMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("ScpFromRemote", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const source = "source"
					const target = "target"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := scp.NewScp(execMock, "", "")

					actual := sut.CopyFromRemote(source, target)

					Expect(actual).To(MatchError(SatisfyAll(
						ContainSubstring(source),
						ContainSubstring(target),
						ContainSubstring(err.Error()),
					)))
				})
			})

			When("cmd exec succeeds", func() {
				It("succeeds", func() {
					const keyPath = "path"
					const remote = "user@host"
					const source = "source"
					const target = "target"
					const expectedRemoteSource = "user@host:source"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-3] == keyPath &&
							arg[len(arg)-2] == expectedRemoteSource &&
							arg[len(arg)-1] == target
					})).Return(nil)

					sut := scp.NewScp(execMock, keyPath, remote)

					err := sut.CopyFromRemote(source, target)

					Expect(err).ToNot(HaveOccurred())

					execMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
