// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package nodes_test

import (
	"errors"
	"log/slog"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/nodes"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/stretchr/testify/mock"
)

type scpMock struct {
	mock.Mock
}

type sshMock struct {
	mock.Mock
}

type fsMock struct {
	mock.Mock
}

type userMock struct {
	mock.Mock
}

type keygenMock struct {
	mock.Mock
}

type aclMock struct {
	mock.Mock
}

func (m *sshMock) Exec(cmd string) error {
	args := m.Called(cmd)

	return args.Error(0)
}

func (m *scpMock) CopyToRemote(source string, target string) error {
	args := m.Called(source, target)

	return args.Error(0)
}

func (m *scpMock) CopyFromRemote(source string, target string) error {
	args := m.Called(source, target)

	return args.Error(0)
}

func (m *fsMock) PathExists(path string) bool {
	args := m.Called(path)

	return args.Bool(0)
}

func (m *fsMock) CreateDirIfNotExisting(path string) error {
	args := m.Called(path)

	return args.Error(0)
}

func (m *fsMock) RemovePaths(files ...string) error {
	args := m.Called(files)

	return args.Error(0)
}

func (m *fsMock) MatchingFiles(pattern string) (matches []string, err error) {
	args := m.Called(pattern)

	return args.Get(0).([]string), args.Error(1)
}

func (m *userMock) Name() string {
	args := m.Called()

	return args.String(0)
}

func (m *userMock) HomeDir() string {
	args := m.Called()

	return args.String(0)
}

func (m *keygenMock) CreateKey(keyPath string, comment string) error {
	args := m.Called(keyPath, comment)

	return args.Error(0)
}

func (m *keygenMock) FindHostInKnownHosts(host string, sshDir string) (string, bool) {
	args := m.Called(host, sshDir)

	return args.String(0), args.Bool(1)
}

func (m *keygenMock) SetHostInKnownHosts(hostEntry string, sshDir string) error {
	args := m.Called(hostEntry, sshDir)

	return args.Error(0)
}

func (m *aclMock) SetOwner(path string, owner string) error {
	args := m.Called(path, owner)

	return args.Error(0)
}

func (m *aclMock) RemoveInheritance(path string) error {
	args := m.Called(path)

	return args.Error(0)
}

func (m *aclMock) GrantFullAccess(path string, username string) error {
	args := m.Called(path, username)

	return args.Error(0)
}

func (m *aclMock) RevokeAccess(path string, username string) error {
	args := m.Called(path, username)

	return args.Error(0)
}

func TestNodesPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "nodes pkg Unit Tests", Label("ci", "unit", "internal", "core", "users", "nodes"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("nodes pkg", func() {

	Describe("DetermineSshRemoteUser", func() {
		It("constructs SSH remote user correctly", func() {
			actual := nodes.DetermineSshRemoteUser("my-IP-address")

			Expect(actual).To(Equal("remote@my-IP-address"))
		})
	})

	Describe("controlPlaneAccess", func() {
		Describe("GrantAccessTo", func() {
			When("searching existing SSH keys failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(true)
					fsMock.On(reflection.GetFunctionName(fsMock.MatchingFiles), mock.Anything).Return([]string{}, expectedError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := nodes.NewControlPlaneAccess(fsMock, nil, nil, nil, nil, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("removing existing SSH keys failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(true)
					fsMock.On(reflection.GetFunctionName(fsMock.MatchingFiles), mock.Anything).Return([]string{}, nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemovePaths), mock.Anything).Return(expectedError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := nodes.NewControlPlaneAccess(fsMock, nil, nil, nil, nil, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("creating SSH dir failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(expectedError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := nodes.NewControlPlaneAccess(fsMock, nil, nil, nil, nil, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("generating SSH key failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, nil, nil, nil, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("setting admin group as file owner failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, nil, nil, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("removing security attribute inheritance failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, nil, nil, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("granting full access to new user failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, nil, nil, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("revoking access for admin user failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, nil, nil, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("removing of existing pub key on control-plane failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", true)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, nil, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("copying pub key to control-plane failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", true)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyToRemote), mock.Anything, mock.Anything).Return(expectedError)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, scpMock, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("adding SSH pub key to authorized keys file on control-plane failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", true)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.MatchedBy(func(cmd string) bool {
						return strings.Contains(cmd, "sudo sed")
					})).Return(expectedError)
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyToRemote), mock.Anything, mock.Anything).Return(nil)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, scpMock, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("host not found in known_hosts file", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", false)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyToRemote), mock.Anything, mock.Anything).Return(nil)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, scpMock, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(SatisfyAll(
						ContainSubstring("could not find"),
						ContainSubstring("entry for host"),
					)))
				})
			})

			When("setting host in known_hosts file failes", func() {
				It("returns error", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", true)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(expectedError)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyToRemote), mock.Anything, mock.Anything).Return(nil)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, scpMock, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("all succeeded", func() {
				It("returns nil", func() {
					const adminSshDir = ""
					const currentUserName = ""
					const k2sUserName = ""

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.PathExists), mock.Anything).Return(false)
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")

					keygenMock := &keygenMock{}
					keygenMock.On(reflection.GetFunctionName(keygenMock.CreateKey), mock.Anything, mock.Anything).Return(nil)
					keygenMock.On(reflection.GetFunctionName(keygenMock.FindHostInKnownHosts), mock.Anything, mock.Anything).Return("", true)
					keygenMock.On(reflection.GetFunctionName(keygenMock.SetHostInKnownHosts), mock.Anything, mock.Anything).Return(nil)

					aclMock := &aclMock{}
					aclMock.On(reflection.GetFunctionName(aclMock.SetOwner), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RemoveInheritance), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.GrantFullAccess), mock.Anything, mock.Anything).Return(nil)
					aclMock.On(reflection.GetFunctionName(aclMock.RevokeAccess), mock.Anything, mock.Anything).Return(nil)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyToRemote), mock.Anything, mock.Anything).Return(nil)

					sut := nodes.NewControlPlaneAccess(fsMock, keygenMock, sshMock, scpMock, aclMock, adminSshDir, "")

					err := sut.GrantAccessTo(userMock, currentUserName, k2sUserName)

					Expect(err).ToNot(HaveOccurred())
				})
			})
		})
	})
})
