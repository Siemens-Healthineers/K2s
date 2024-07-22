// SPDX-FileCopyrightText:  © 2023 Siemens Healthcare GmbH
// SPDX-License-Identifier:   MIT

package acl_test

import (
	"errors"
	"log/slog"
	"testing"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/reflection"
	"github.com/siemens-healthineers/k2s/internal/windows/acl"
	"github.com/stretchr/testify/mock"
)

type cmdExecutorMock struct {
	mock.Mock
}

func (m *cmdExecutorMock) ExecuteCmd(name string, arg ...string) error {
	args := m.Called(name, arg)

	return args.Error(0)
}

func TestAclPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "acl pkg Unit Tests", Label("unit", "ci", "windows", "acl"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("acl pkg", func() {
	Describe("SetOwner", func() {
		When("cmd exec returns error", func() {
			It("returns error", func() {
				const path = "path"
				const owner = "owner"
				err := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

				sut := acl.NewAcl(execMock)

				actual := sut.SetOwner(path, owner)

				Expect(actual).To(MatchError(SatisfyAll(
					ContainSubstring(path),
					ContainSubstring(owner),
					ContainSubstring(err.Error()),
				)))
			})
		})

		When("cmd exec succeeds", func() {
			It("succeeds", func() {
				const path = "path"
				const owner = "owner"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

				sut := acl.NewAcl(execMock)

				err := sut.SetOwner(path, owner)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("RemoveInheritance", func() {
		When("cmd exec returns error", func() {
			It("returns error", func() {
				const path = "path"
				err := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

				sut := acl.NewAcl(execMock)

				actual := sut.RemoveInheritance(path)

				Expect(actual).To(MatchError(SatisfyAll(
					ContainSubstring(path),
					ContainSubstring(err.Error()),
				)))
			})
		})

		When("cmd exec succeeds", func() {
			It("succeeds", func() {
				const path = "path"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

				sut := acl.NewAcl(execMock)

				err := sut.RemoveInheritance(path)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("GrantFullAccess", func() {
		When("cmd exec returns error", func() {
			It("returns error", func() {
				const path = "path"
				const username = "user"
				err := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

				sut := acl.NewAcl(execMock)

				actual := sut.GrantFullAccess(path, username)

				Expect(actual).To(MatchError(SatisfyAll(
					ContainSubstring(path),
					ContainSubstring(username),
					ContainSubstring(err.Error()),
				)))
			})
		})

		When("cmd exec succeeds", func() {
			It("succeeds", func() {
				const path = "path"
				const username = "user"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

				sut := acl.NewAcl(execMock)

				err := sut.GrantFullAccess(path, username)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})

	Describe("RevokeAccess", func() {
		When("cmd exec returns error", func() {
			It("returns error", func() {
				const path = "path"
				const username = "user"
				err := errors.New("oops")

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(err)

				sut := acl.NewAcl(execMock)

				actual := sut.RevokeAccess(path, username)

				Expect(actual).To(MatchError(SatisfyAll(
					ContainSubstring(path),
					ContainSubstring(username),
					ContainSubstring(err.Error()),
				)))
			})
		})

		When("cmd exec succeeds", func() {
			It("succeeds", func() {
				const path = "path"
				const username = "user"

				execMock := &cmdExecutorMock{}
				execMock.On(reflection.GetFunctionName(execMock.ExecuteCmd), mock.Anything, mock.Anything).Return(nil)

				sut := acl.NewAcl(execMock)

				err := sut.RevokeAccess(path, username)

				Expect(err).ToNot(HaveOccurred())
			})
		})
	})
})
