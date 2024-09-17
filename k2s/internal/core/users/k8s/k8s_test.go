// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package k8s_test

import (
	"errors"
	"log/slog"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/cluster"
	"github.com/siemens-healthineers/k2s/internal/core/users/k8s/kubeconfig"
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

type clusterMock struct {
	mock.Mock
}

type factoryMock struct {
	mock.Mock
}

type readerMock struct {
	mock.Mock
}

type writerMock struct {
	mock.Mock
}

func (m *sshMock) Exec(cmd string) error {
	args := m.Called(cmd)

	return args.Error(0)
}

func (m *scpMock) CopyFromRemote(source string, target string) error {
	args := m.Called(source, target)

	return args.Error(0)
}

func (m *fsMock) CreateDirIfNotExisting(path string) error {
	args := m.Called(path)

	return args.Error(0)
}

func (m *fsMock) RemoveAll(path string) error {
	args := m.Called(path)

	return args.Error(0)
}

func (m *clusterMock) VerifyAccess(userParam *cluster.UserParam, clusterParam *cluster.ClusterParam) error {
	args := m.Called(userParam, clusterParam)

	return args.Error(0)
}

func (m *readerMock) ReadFile(path string) (*kubeconfig.KubeconfigRoot, error) {
	args := m.Called(path)

	return args.Get(0).(*kubeconfig.KubeconfigRoot), args.Error(1)
}

func (m *factoryMock) NewKubeconfigWriter(filePath string) k8s.KubeconfigWriter {
	args := m.Called(filePath)

	return args.Get(0).(k8s.KubeconfigWriter)
}

func (m *writerMock) FilePath() string {
	args := m.Called()

	return args.String(0)
}

func (m *writerMock) SetCluster(clusterConfig *kubeconfig.ClusterEntry) error {
	args := m.Called(clusterConfig)

	return args.Error(0)
}

func (m *writerMock) SetCredentials(username, certPath, keyPath string) error {
	args := m.Called(username, certPath, keyPath)

	return args.Error(0)
}

func (m *writerMock) SetContext(context, username, clusterName string) error {
	args := m.Called(context, username, clusterName)

	return args.Error(0)
}

func (m *writerMock) UseContext(context string) error {
	args := m.Called(context)

	return args.Error(0)
}

func (m *userMock) Name() string {
	args := m.Called()

	return args.String(0)
}

func (m *userMock) HomeDir() string {
	args := m.Called()

	return args.String(0)
}

func TestK8sPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "k8s pkg Tests", Label("ci", "unit", "internal", "core", "users", "k8s"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("k8s pkg", func() {
	Describe("k8sAccess", func() {
		Describe("GrantAccessTo", func() {
			When("kubeconfig dir cannot be created", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(expectedError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					sut := k8s.NewK8sAccess(nil, nil, fsMock, nil, nil, nil, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("admin's kubeconfig file cannot be read", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(&kubeconfig.KubeconfigRoot{}, expectedError)

					sut := k8s.NewK8sAccess(nil, nil, fsMock, nil, nil, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("cluster not found in admin's kubeconfig", func() {
				It("returns error", func() {
					adminConfig := &kubeconfig.KubeconfigRoot{}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					sut := k8s.NewK8sAccess(nil, nil, fsMock, nil, nil, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(ContainSubstring("cluster 'kubernetes' not found")))
				})
			})

			When("setting cluster config failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(expectedError)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sut := k8s.NewK8sAccess(nil, nil, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("creating user cert on control-plane failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(expectedError)

					sut := k8s.NewK8sAccess(sshMock, nil, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("copying user cert from control-plane failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(expectedError)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("removing temp cert dir on control-plane failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.MatchedBy(func(cmd string) bool {
						return strings.Contains(cmd, "sudo openssl")
					})).Return(nil)
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.MatchedBy(func(cmd string) bool {
						return !strings.Contains(cmd, "sudo openssl") && strings.Contains(cmd, "rm -rf")
					})).Return(expectedError)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("setting credentials config failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(expectedError)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("removing local cert files failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(expectedError)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("setting context config failes", func() {
				It("returns error", func() {
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.Anything).Return(adminConfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return("")
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(expectedError)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, "")

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("reading new kubeconfig failes", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(&kubeconfig.KubeconfigRoot{}, expectedError)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("using K2s context failes", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), mock.Anything).Return(expectedError)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, "")

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("user config not found", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: "wrong-user",
							},
						},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), mock.Anything).Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).To(MatchError(ContainSubstring("user 'wanna-have-access' not found")))
				})
			})

			When("cluster config not found", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: userName,
							},
						},
						Clusters: []kubeconfig.ClusterEntry{
							{
								Name: "wrong-cluster",
							},
						},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), mock.Anything).Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, nil, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).To(MatchError(ContainSubstring("cluster 'kubernetes' not found")))
				})
			})

			When("cluster access verification failes", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					expectedError := errors.New("oops")
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: userName,
							},
						},
						Clusters: []kubeconfig.ClusterEntry{
							{
								Name: "kubernetes",
							},
						},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), mock.Anything).Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					clusterMock := &clusterMock{}
					clusterMock.On(reflection.GetFunctionName(clusterMock.VerifyAccess), mock.Anything, mock.Anything).Return(expectedError)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, clusterMock, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("new user had no other K8s context before", func() {
				It("does not reset context", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					clusterConfig := &kubeconfig.ClusterEntry{Name: "kubernetes"}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: userName,
							},
						},
						Clusters: []kubeconfig.ClusterEntry{
							{
								Name: "kubernetes",
							},
						},
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), mock.Anything).Once().Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					clusterMock := &clusterMock{}
					clusterMock.On(reflection.GetFunctionName(clusterMock.VerifyAccess), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, clusterMock, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).ToNot(HaveOccurred())
					writerMock.AssertExpectations(GinkgoT())
				})
			})

			When("resetting to other context after access verification failes", func() {
				It("returns error", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					const clusterName = "kubernetes"
					const otherContext = "my-other-context"
					expectedError := errors.New("oops")
					k2sContext := userName + "@" + clusterName
					clusterConfig := &kubeconfig.ClusterEntry{Name: clusterName}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: userName,
							},
						},
						Clusters: []kubeconfig.ClusterEntry{
							{
								Name: clusterName,
							},
						},
						CurrentContext: otherContext,
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), k2sContext).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), otherContext).Return(expectedError)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					clusterMock := &clusterMock{}
					clusterMock.On(reflection.GetFunctionName(clusterMock.VerifyAccess), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, clusterMock, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).To(MatchError(expectedError))
				})
			})

			When("new user had other K8s context before", func() {
				It("resets to other context after access verification", func() {
					const adminDir = "admin-dir"
					const newKubeconfigPath = "new-kubeconfig"
					const userName = "wanna-have-access"
					const clusterName = "kubernetes"
					const otherContext = "my-other-context"
					k2sContext := userName + "@" + clusterName
					clusterConfig := &kubeconfig.ClusterEntry{Name: clusterName}
					adminConfig := &kubeconfig.KubeconfigRoot{
						Clusters: []kubeconfig.ClusterEntry{*clusterConfig},
					}
					newKubeconfig := &kubeconfig.KubeconfigRoot{
						Users: []kubeconfig.UserEntry{
							{
								Name: userName,
							},
						},
						Clusters: []kubeconfig.ClusterEntry{
							{
								Name: clusterName,
							},
						},
						CurrentContext: otherContext,
					}

					fsMock := &fsMock{}
					fsMock.On(reflection.GetFunctionName(fsMock.CreateDirIfNotExisting), mock.Anything).Return(nil)
					fsMock.On(reflection.GetFunctionName(fsMock.RemoveAll), mock.Anything).Return(nil)

					userMock := &userMock{}
					userMock.On(reflection.GetFunctionName(userMock.Name)).Return("")
					userMock.On(reflection.GetFunctionName(userMock.HomeDir)).Return("")

					readerMock := &readerMock{}
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), mock.MatchedBy(func(path string) bool {
						return strings.Contains(path, adminDir)
					})).Return(adminConfig, nil)
					readerMock.On(reflection.GetFunctionName(readerMock.ReadFile), newKubeconfigPath).Return(newKubeconfig, nil)

					writerMock := &writerMock{}
					writerMock.On(reflection.GetFunctionName(writerMock.SetCluster), clusterConfig).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.FilePath)).Return(newKubeconfigPath)
					writerMock.On(reflection.GetFunctionName(writerMock.SetCredentials), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.SetContext), mock.Anything, mock.Anything, mock.Anything).Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), k2sContext).Once().Return(nil)
					writerMock.On(reflection.GetFunctionName(writerMock.UseContext), otherContext).Once().Return(nil)

					factoryMock := &factoryMock{}
					factoryMock.On(reflection.GetFunctionName(factoryMock.NewKubeconfigWriter), mock.Anything).Return(writerMock)

					sshMock := &sshMock{}
					sshMock.On(reflection.GetFunctionName(sshMock.Exec), mock.Anything).Return(nil)

					scpMock := &scpMock{}
					scpMock.On(reflection.GetFunctionName(scpMock.CopyFromRemote), mock.Anything, mock.Anything).Return(nil)

					clusterMock := &clusterMock{}
					clusterMock.On(reflection.GetFunctionName(clusterMock.VerifyAccess), mock.Anything, mock.Anything).Return(nil)

					sut := k8s.NewK8sAccess(sshMock, scpMock, fsMock, clusterMock, factoryMock, readerMock, adminDir)

					err := sut.GrantAccessTo(userMock, userName)

					Expect(err).ToNot(HaveOccurred())
					writerMock.AssertExpectations(GinkgoT())
				})
			})
		})
	})
})
