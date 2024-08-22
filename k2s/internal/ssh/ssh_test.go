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

type execMock struct {
	mock.Mock
}

type fsMock struct {
	mock.Mock
}

func (m *execMock) ExecuteCmd(name string, arg ...string) error {
	args := m.Called(name, arg)

	return args.Error(0)
}

func (m *fsMock) PathExists(path string) bool {
	args := m.Called(path)

	return args.Bool(0)
}

func (m *fsMock) AppendToFile(path string, text string) error {
	args := m.Called(path, text)

	return args.Error(0)
}

func (m *fsMock) ReadFile(path string) ([]byte, error) {
	args := m.Called(path)

	return args.Get(0).([]byte), args.Error(1)
}

func (m *fsMock) WriteFile(path string, data []byte) error {
	args := m.Called(path, data)

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

					execMock := &execMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := ssh.NewSshKeyGen(execMock, nil)

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

					execMock := &execMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

					sut := ssh.NewSshKeyGen(execMock, nil)

					err := sut.CreateKey(file, comment)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})

		Describe("FindHostInKnownHosts", func() {
			When("read error occurred", func() {
				It("returns empty entry and false", func() {
					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), mock.Anything).Return([]byte{}, errors.New("oops"))

					sut := ssh.NewSshKeyGen(nil, fsMock)

					entry, found := sut.FindHostInKnownHosts("", "")

					Expect(entry).To(BeEmpty())
					Expect(found).To(BeFalse())
				})
			})

			When("no host found", func() {
				It("returns empty entry and false", func() {
					const hostFile = "one this-is-host-one\ntwo this-is-host-two\n"

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), mock.Anything).Return([]byte(hostFile), nil)

					sut := ssh.NewSshKeyGen(nil, fsMock)

					entry, found := sut.FindHostInKnownHosts("three", "")

					Expect(entry).To(BeEmpty())
					Expect(found).To(BeFalse())
				})
			})

			When("host found", func() {
				It("returns host entry and true", func() {
					const hostFile = "one this-is-host-one\ntwo this-is-host-two\nthree this-is-host-three\n"

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), mock.Anything).Return([]byte(hostFile), nil)

					sut := ssh.NewSshKeyGen(nil, fsMock)

					entry, found := sut.FindHostInKnownHosts("three", "")

					Expect(entry).To(Equal("three this-is-host-three\n"))
					Expect(found).To(BeTrue())
				})
			})
		})

		Describe("SetHostInKnownHosts", func() {
			When("known_hosts exist", func() {
				When("host entry exists", func() {
					When("removing existing entry failed", func() {
						It("returns error", func() {
							const dir = "my-dir"
							const filePath = dir + "\\known_hosts"
							const hostEntry = "my-host some-data\n"
							const knownHosts = "my-host some-data\nother-host some-more-data\n"

							err := errors.New("oops")

							execMock := &execMock{}
							execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

							fsMock := &fsMock{}
							fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
							fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)

							sut := ssh.NewSshKeyGen(execMock, fsMock)

							actualErr := sut.SetHostInKnownHosts(hostEntry, dir)

							Expect(actualErr).To(MatchError(err))
						})
					})

					When("removing existing entry succeeded", func() {
						It("appends to file", func() {
							const dir = "my-dir"
							const filePath = dir + "\\known_hosts"
							const hostEntry = "my-host some-data\n"
							const knownHosts = "my-host some-data\nother-host some-more-data\n"

							execMock := &execMock{}
							execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

							fsMock := &fsMock{}
							fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
							fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)
							fsMock.On(reflection.GetFunctionName(fsMock.AppendToFile), filePath, hostEntry).Return(nil).Once()

							sut := ssh.NewSshKeyGen(execMock, fsMock)

							err := sut.SetHostInKnownHosts(hostEntry, dir)

							Expect(err).ToNot(HaveOccurred())
							fsMock.AssertExpectations(GinkgoT())
						})
					})
				})

				When("host entry does not exist", func() {
					It("appends to file", func() {
						const dir = "my-dir"
						const filePath = dir + "\\known_hosts"
						const hostEntry = "my-host some-data\n"
						const knownHosts = "other-host some-more-data\n"

						fsMock := &fsMock{}
						fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
						fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)
						fsMock.On(reflection.GetFunctionName(fsMock.AppendToFile), filePath, hostEntry).Return(nil).Once()

						sut := ssh.NewSshKeyGen(nil, fsMock)

						err := sut.SetHostInKnownHosts(hostEntry, dir)

						Expect(err).ToNot(HaveOccurred())
						fsMock.AssertExpectations(GinkgoT())
					})
				})

				When("appending to file failed", func() {
					It("returns error", func() {
						const dir = "my-dir"
						const filePath = dir + "\\known_hosts"
						const hostEntry = "my-host some-data\n"
						const knownHosts = "other-host some-more-data\n"

						err := errors.New("oops")

						fsMock := &fsMock{}
						fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
						fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)
						fsMock.On(reflection.GetFunctionName(fsMock.AppendToFile), filePath, hostEntry).Return(err)

						sut := ssh.NewSshKeyGen(nil, fsMock)

						actualErr := sut.SetHostInKnownHosts(hostEntry, dir)

						Expect(actualErr).To(MatchError(err))
					})
				})
			})

			When("known_hosts does not exist", func() {
				When("creation failed", func() {
					It("returns error", func() {
						const dir = "my-dir"
						const filePath = dir + "\\known_hosts"
						const hostEntry = "my-host some-data\n"

						err := errors.New("oops")

						fsMock := &fsMock{}
						fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(false)
						fsMock.On(reflection.GetFunctionName(fsMock.WriteFile), filePath, []byte(hostEntry)).Return(err)

						sut := ssh.NewSshKeyGen(nil, fsMock)

						actualErr := sut.SetHostInKnownHosts(hostEntry, dir)

						Expect(actualErr).To(MatchError(err))
					})
				})

				When("creation succeeds", func() {
					It("creates known_hosts file", func() {
						const dir = "my-dir"
						const filePath = dir + "\\known_hosts"
						const hostEntry = "my-host some-data\n"

						fsMock := &fsMock{}
						fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(false)
						fsMock.On(reflection.GetFunctionName(fsMock.WriteFile), filePath, []byte(hostEntry)).Return(nil).Once()

						sut := ssh.NewSshKeyGen(nil, fsMock)

						err := sut.SetHostInKnownHosts(hostEntry, dir)

						Expect(err).ToNot(HaveOccurred())
						fsMock.AssertExpectations(GinkgoT())
					})
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

				execMock := &execMock{}
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

					execMock := &execMock{}
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

					execMock := &execMock{}
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

					execMock := &execMock{}
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

					execMock := &execMock{}
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

					execMock := &execMock{}
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

					execMock := &execMock{}
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
