// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package keygen_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh/keygen"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type cmdExecutorMock struct {
	mock.Mock
}

type fsMock struct {
	mock.Mock
}

func (m *cmdExecutorMock) ExecuteCmd(name string, arg ...string) error {
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

func TestKeygenPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "keygen pkg Tests", Label("ci", "unit", "internal", "core", "node", "keygen"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("keygen pkg", func() {
	Describe("sshKeyGen", func() {
		Describe("CreateKey", func() {
			When("cmd exec returns error", func() {
				It("returns error", func() {
					const file = "file"
					const comment = "comment"
					err := errors.New("oops")

					execMock := &cmdExecutorMock{}
					execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

					sut := keygen.NewSshKeyGen(execMock, nil)

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

					sut := keygen.NewSshKeyGen(execMock, nil)

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

					sut := keygen.NewSshKeyGen(nil, fsMock)

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

					sut := keygen.NewSshKeyGen(nil, fsMock)

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

					sut := keygen.NewSshKeyGen(nil, fsMock)

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

							execMock := &cmdExecutorMock{}
							execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

							fsMock := &fsMock{}
							fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
							fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)

							sut := keygen.NewSshKeyGen(execMock, fsMock)

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

							execMock := &cmdExecutorMock{}
							execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

							fsMock := &fsMock{}
							fsMock.On(reflection.GetFunctionName(fsMock.PathExists), filePath).Return(true)
							fsMock.On(reflection.GetFunctionName(fsMock.ReadFile), filePath).Return([]byte(knownHosts), nil)
							fsMock.On(reflection.GetFunctionName(fsMock.AppendToFile), filePath, hostEntry).Return(nil).Once()

							sut := keygen.NewSshKeyGen(execMock, fsMock)

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

						sut := keygen.NewSshKeyGen(nil, fsMock)

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

						sut := keygen.NewSshKeyGen(nil, fsMock)

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

						sut := keygen.NewSshKeyGen(nil, fsMock)

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

						sut := keygen.NewSshKeyGen(nil, fsMock)

						err := sut.SetHostInKnownHosts(hostEntry, dir)

						Expect(err).ToNot(HaveOccurred())
						fsMock.AssertExpectations(GinkgoT())
					})
				})
			})
		})
	})
})
