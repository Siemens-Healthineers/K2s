// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package ssh_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/nodes/ssh"
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

func TestSshPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ssh pkg Unit Tests", Label("ci", "unit", "internal", "core", "users", "nodes", "ssh"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ssh pkg", func() {
	Describe("ssh", func() {
		Describe("Exec", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const cmd = "cmd"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := ssh.NewSsh(execMock, "", "")

					actual := sut.Exec(cmd)

					Expect(actual).To(MatchError(SatisfyAll(
						ContainSubstring(cmd),
						ContainSubstring(err.Error()),
					)))
				})
			})

			When("cmd exec succeeds", func() {
				It("succeeds", func() {
					const cmd = "cmd"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-1] == cmd
					})).Return(nil)

					sut := ssh.NewSsh(execMock, "", "")

					err := sut.Exec(cmd)

					Expect(err).ToNot(HaveOccurred())

					execMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
