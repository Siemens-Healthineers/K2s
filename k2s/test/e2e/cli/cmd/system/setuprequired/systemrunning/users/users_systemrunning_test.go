// SPDX-FileCopyrightText:  © 2024 Siemens Healthcare AG
// SPDX-License-Identifier:   MIT

package users_test

import (
	"context"
	"errors"
	"log/slog"
	"os/user"
	"path/filepath"
	"testing"
	"time"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/samber/lo"

	"github.com/siemens-healthineers/k2s/internal/core/config"
	"github.com/siemens-healthineers/k2s/internal/core/users"
	"github.com/siemens-healthineers/k2s/internal/core/users/winusers"
	"github.com/siemens-healthineers/k2s/internal/os"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

type ginkgoWriter struct{}

type winUserProvider struct {
	findByName func(name string) (*winusers.User, error)
	getCurrent func() (*winusers.User, error)
}

const systemUserId = "S-1-5-18"
const systemUserName = "NT AUTHORITY\\SYSTEM"

var suite *framework.K2sTestSuite

func (gw *ginkgoWriter) WriteStdOut(message string) {
	GinkgoWriter.Println(message)
}

func (gw *ginkgoWriter) WriteStdErr(message string) {
	GinkgoWriter.Println(message)
}

func (gw *ginkgoWriter) Flush() {
	// stub
}

func (p *winUserProvider) FindByName(name string) (*winusers.User, error) {
	return p.findByName(name)
}

func (p *winUserProvider) FindById(id string) (*winusers.User, error) {
	return nil, errors.New("not implemented")
}

func (p *winUserProvider) Current() (*winusers.User, error) {
	return p.getCurrent()
}

func TestUsers(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "system users Acceptance Tests", Label("cli", "system", "users", "add", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("system users add", Ordered, func() {
	When("user is SYSTEM user", func() {
		var userProvider *winUserProvider
		var expectedKeyPath string
		var expectedRemoteUser string

		BeforeAll(func() {
			fakeHomeDir := filepath.Join(GinkgoT().TempDir(), systemUserId)
			GinkgoWriter.Println("Using temp home dir <", fakeHomeDir, ">")

			controlPlaneConfig, found := lo.Find(suite.SetupInfo().Config.Nodes(), func(node config.NodeConfigReader) bool {
				return node.IsControlPlane()
			})
			Expect(found).To(BeTrue())
			expectedRemoteUser = "remote@" + controlPlaneConfig.IpAddress()
			expectedKeyPath = filepath.Join(fakeHomeDir, `.ssh\k2s\id_rsa`)

			systemUserWithFakeHomeDir := winusers.NewUser(systemUserId, systemUserName, fakeHomeDir)

			userProvider = &winUserProvider{
				findByName: func(_ string) (*winusers.User, error) { return systemUserWithFakeHomeDir, nil },
				getCurrent: winusers.NewWinUserProvider().Current,
			}
		})

		It("grants Windows SYSTEM user access to K2s", MustPassRepeatedly(2), func(ctx context.Context) {
			sut, err := users.NewUsersManagement(suite.SetupInfo().Config, os.NewCmdExecutor(&ginkgoWriter{}), userProvider)

			Expect(err).ToNot(HaveOccurred())
			Expect(sut).ToNot(BeNil())

			Expect(sut.AddUserByName(systemUserName)).To(Succeed())

			output := suite.Cli().ExecOrFail(ctx, "ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", expectedKeyPath, expectedRemoteUser, "echo 'SSH access test successful'")

			Expect(output).To(ContainSubstring("SSH access test successful"))
		})
	})

	When("user not found by name", func() {
		It("prints not-found warning", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "users", "add", "-u", "non-existent-name")

			Expect(output).To(SatisfyAll(
				ContainSubstring("WARNING"),
				ContainSubstring("could not find"),
				ContainSubstring("name 'non-existent-name'"),
			))
		})
	})

	When("user not found by id", func() {
		It("prints not-found warning", func(ctx context.Context) {
			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "users", "add", "-i", "non-existent-id")

			Expect(output).To(SatisfyAll(
				ContainSubstring("WARNING"),
				ContainSubstring("could not find"),
				ContainSubstring("id 'non-existent-id'"),
			))
		})
	})

	When("user is current admin user", func() {
		It("prints error", func(ctx context.Context) {
			currentUser, err := user.Current()
			Expect(err).ToNot(HaveOccurred())

			output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "system", "users", "add", "-i", currentUser.Uid)

			Expect(output).To(SatisfyAll(
				ContainSubstring("ERROR"),
				ContainSubstring("cannot overwrite"),
				ContainSubstring("current Windows user"),
				ContainSubstring(currentUser.Uid),
				ContainSubstring(currentUser.Username),
			))
		})
	})
})
