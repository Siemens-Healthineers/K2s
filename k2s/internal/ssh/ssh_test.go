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
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/siemens-healthineers/k2s/internal/ssh"
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
	RunSpecs(t, "ssh pkg Unit Tests", Label("unit", "ci", "ssh"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ssh pkg", func() {
	Describe("sshKeyGen", func() {
		Describe("CreateKey", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const file = "file"
					const comment = "comment"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := ssh.NewSshKeyGen(execMock)

					actual := sut.CreateKey(file, comment)

					Expect(actual).To(MatchError(SatisfyAll(
						ContainSubstring(file),
						ContainSubstring(err.Error()),
					)))
				})
			})

			When("cmd exec succeeds", func() {
				It("succeeds", func() {
					const file = "file"
					const comment = "comment"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

					sut := ssh.NewSshKeyGen(execMock)

					err := sut.CreateKey(file, comment)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})
	})

	Describe("ssh", func() {
		Describe("SetConfig", func() {
			It("constructs remote correctly", func() {
				const keyPath = "path"
				const user = "user"
				const host = "host"
				const expectedRemote = "user@host"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
					return arg[len(arg)-3] == keyPath &&
						arg[len(arg)-2] == expectedRemote
				})).Return(nil)

				sut := ssh.NewSsh(execMock)

				sut.SetConfig(keyPath, user, host)

				err := sut.Exec("")
				Expect(err).ToNot(HaveOccurred())

				execMock.AssertExpectations(GinkgoT())
			})
		})

		Describe("Exec", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const cmd = "cmd"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := ssh.NewSsh(execMock)

					actual := sut.Exec(cmd)

					Expect(actual).To(MatchError(SatisfyAll(
						ContainSubstring(cmd),
						ContainSubstring(err.Error()),
					)))
				})
			})

			When("cmd exec succeeds", func() {
				It("succeeds", func() {
					const keyPath = "path"
					const user = "user"
					const host = "host"
					const cmd = "cmd"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-1] == cmd
					})).Return(nil)

					sut := ssh.NewSsh(execMock)
					sut.SetConfig(keyPath, user, host)

					err := sut.Exec(cmd)

					Expect(err).ToNot(HaveOccurred())

					execMock.AssertExpectations(GinkgoT())
				})
			})
		})

		Describe("ScpToRemote", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const source = "source"
					const target = "target"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := ssh.NewSsh(execMock)

					actual := sut.ScpToRemote(source, target)

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
					const user = "user"
					const host = "host"
					const source = "source"
					const target = "target"
					const expectedRemotePath = "user@host:target"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-3] == keyPath &&
							arg[len(arg)-2] == source &&
							arg[len(arg)-1] == expectedRemotePath
					})).Return(nil)

					sut := ssh.NewSsh(execMock)
					sut.SetConfig(keyPath, user, host)

					err := sut.ScpToRemote(source, target)

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

					sut := ssh.NewSsh(execMock)

					actual := sut.ScpFromRemote(source, target)

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
					const user = "user"
					const host = "host"
					const source = "source"
					const target = "target"
					const expectedRemotePath = "user@host:source"

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.MatchedBy(func(arg []string) bool {
						return arg[len(arg)-3] == keyPath &&
							arg[len(arg)-2] == expectedRemotePath &&
							arg[len(arg)-1] == target
					})).Return(nil)

					sut := ssh.NewSsh(execMock)
					sut.SetConfig(keyPath, user, host)

					err := sut.ScpFromRemote(source, target)

					Expect(err).ToNot(HaveOccurred())

					execMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
